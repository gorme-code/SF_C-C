/**
 * Invoked by the Create_Closure_Events flow (after insert on a Closure_Submission Case).
 * Expands one submission into N Closure_Event__c rows (one per affected school per date ENTRY),
 * skipping duplicates, acknowledges the Case, then performs the tier-boundary check.
 *
 * v1.3 per-date model: the submission carries a JSON array in Case.Closure_Date_Entries__c.
 * Each entry is fully independent (its own date, type, reason, hours, make-up method, eLearning
 * day number, scheduled make-up date). This replaces the old single-reason date-range model that
 * read Closure_Start_Date__c / Closure_End_Date__c. Those legacy fields are retained on Case for
 * existing records but are no longer read here.
 *
 * Tier-boundary handling lives here (not in the Tier_Boundary_Check flow) because events are
 * bulk-inserted: a per-record "previous total" flow can't detect a crossing when all rows
 * arrive at once. Processing the whole batch in Apex is race-free and lets us set
 * Total_Missed_Days__c on the waiver so its Tier__c formula resolves correctly.
 *
 * District__c on each event is set by the before-save Populate_District_On_Event flow.
 */
public with sharing class ExpandClosureSubmission {

    public class Request {
        @InvocableVariable(label='Case Id' required=true)
        public Id caseId;
    }

    /** One parsed element of the Closure_Date_Entries__c JSON array. */
    private class DateEntry {
        Date closureDate;
        String closureType;
        String closureReason;
        Decimal hoursMissed;
        String makeUpMethod;
        Integer elearningDayNumber;
        Date scheduledMakeupDate;
    }

    @InvocableMethod(label='Expand Closure Submission' description='Creates Closure_Event__c rows from a Closure Submission Case, acknowledges the Case, and auto-creates waiver cases on tier-boundary crossings.')
    public static void run(List<Request> requests) {
        Set<Id> caseIds = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.caseId != null) {
                caseIds.add(r.caseId);
            }
        }
        if (caseIds.isEmpty()) {
            return;
        }

        List<Case> cases = [
            SELECT Id, Submission_Scope__c, Submission_District__c, Affected_School_IDs__c,
                   Closure_Date_Entries__c, Submission_Comments__c,
                   Reported_By_Contact__c, Submission_Status__c
            FROM Case
            WHERE Id IN :caseIds
        ];

        // 1a. Bulk-resolve district-wide school lookups
        Set<Id> districtIds = new Set<Id>();
        for (Case c : cases) {
            if (c.Submission_Scope__c == 'District_Wide' && c.Submission_District__c != null) {
                districtIds.add(c.Submission_District__c);
            }
        }
        Map<Id, List<Id>> schoolsByDistrict = new Map<Id, List<Id>>();
        if (!districtIds.isEmpty()) {
            for (Account a : [
                SELECT Id, ParentId FROM Account
                WHERE ParentId IN :districtIds AND RecordType.DeveloperName = 'School'
            ]) {
                if (!schoolsByDistrict.containsKey(a.ParentId)) {
                    schoolsByDistrict.put(a.ParentId, new List<Id>());
                }
                schoolsByDistrict.get(a.ParentId).add(a.Id);
            }
        }

        // 1b. Resolve schools + 2. parse date entries per case
        Map<Id, List<Id>> schoolsByCase = new Map<Id, List<Id>>();
        Map<Id, List<DateEntry>> entriesByCase = new Map<Id, List<DateEntry>>();
        Set<Id> allSchoolIds = new Set<Id>();
        Date minDate;
        Date maxDate;

        for (Case c : cases) {
            List<Id> schoolIds = new List<Id>();
            if (c.Submission_Scope__c == 'District_Wide') {
                if (schoolsByDistrict.containsKey(c.Submission_District__c)) {
                    schoolIds.addAll(schoolsByDistrict.get(c.Submission_District__c));
                }
            } else if (String.isNotBlank(c.Affected_School_IDs__c)) {
                // Single_School (one id) and Multiple_Schools (comma list) both carry ids here
                for (String part : c.Affected_School_IDs__c.split(',')) {
                    String token = part.trim();
                    if (String.isBlank(token)) {
                        continue;
                    }
                    try {
                        schoolIds.add((Id) token);
                    } catch (Exception e) {
                        // skip malformed id token
                    }
                }
            }
            schoolsByCase.put(c.Id, schoolIds);
            allSchoolIds.addAll(schoolIds);

            List<DateEntry> entries = parseEntries(c.Closure_Date_Entries__c);
            entriesByCase.put(c.Id, entries);

            for (DateEntry de : entries) {
                if (minDate == null || de.closureDate < minDate) { minDate = de.closureDate; }
                if (maxDate == null || de.closureDate > maxDate) { maxDate = de.closureDate; }
            }
        }

        // 3a. One bulk query for existing events in range (dup-check)
        Set<String> existingKeys = new Set<String>();
        if (!allSchoolIds.isEmpty() && minDate != null && maxDate != null) {
            for (Closure_Event__c ev : [
                SELECT School__c, Closure_Date__c FROM Closure_Event__c
                WHERE School__c IN :allSchoolIds
                AND Closure_Date__c >= :minDate AND Closure_Date__c <= :maxDate
            ]) {
                existingKeys.add(keyOf(ev.School__c, ev.Closure_Date__c));
            }
        }

        // 3b/4. Build new events for each (school x entry), skipping existing + intra-batch dups
        List<Closure_Event__c> toCreate = new List<Closure_Event__c>();
        Set<String> plannedKeys = new Set<String>();
        Datetime nowTs = Datetime.now();
        for (Case c : cases) {
            List<Id> schoolIds = schoolsByCase.get(c.Id);
            List<DateEntry> entries = entriesByCase.get(c.Id);
            if (schoolIds == null || entries == null) {
                continue;
            }
            for (Id sid : schoolIds) {
                for (DateEntry de : entries) {
                    String key = keyOf(sid, de.closureDate);
                    if (existingKeys.contains(key) || plannedKeys.contains(key)) {
                        continue;
                    }
                    plannedKeys.add(key);
                    Closure_Event__c ev = new Closure_Event__c(
                        School__c = sid,
                        Source_Case__c = c.Id,
                        Closure_Date__c = de.closureDate,
                        Closure_Reason__c = de.closureReason,
                        Closure_Type__c = de.closureType,
                        Hours_Missed__c = (de.hoursMissed != null ? de.hoursMissed : 6.5),
                        Make_Up_Method__c = de.makeUpMethod,
                        Scheduled_Makeup_Date__c = de.scheduledMakeupDate,
                        Comments__c = c.Submission_Comments__c,
                        Reported_By__c = c.Reported_By_Contact__c,
                        Reported_Date__c = nowTs,
                        Status__c = 'Submitted'
                    );
                    if (de.elearningDayNumber != null) {
                        // eLearning_Day_Number__c is a text picklist (values '1'..'5')
                        ev.eLearning_Day_Number__c = String.valueOf(de.elearningDayNumber);
                    }
                    toCreate.add(ev);
                }
            }
        }

        if (!toCreate.isEmpty()) {
            insert toCreate; // Set_Make_Up_Required runs here and sets Make_Up_Required__c
        }

        // 5. Acknowledge the cases
        List<Case> toUpdate = new List<Case>();
        for (Case c : cases) {
            toUpdate.add(new Case(Id = c.Id, Submission_Status__c = 'Acknowledged'));
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        // Tier-boundary check across all affected schools (bulk-safe, race-free)
        checkTierBoundaries(allSchoolIds);
    }

    /** Deserialize Closure_Date_Entries__c into typed entries; malformed/blank input yields []. */
    private static List<DateEntry> parseEntries(String jsonStr) {
        List<DateEntry> result = new List<DateEntry>();
        if (String.isBlank(jsonStr)) {
            return result;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(jsonStr);
        } catch (Exception e) {
            return result; // malformed JSON -> no entries (no events created)
        }
        if (!(parsed instanceof List<Object>)) {
            return result;
        }
        for (Object o : (List<Object>) parsed) {
            if (!(o instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> m = (Map<String, Object>) o;
            Date startDate = toDate(m.get('date'));
            if (startDate == null) {
                continue; // an entry with no valid date cannot key an event
            }
            Date endDate = toDate(m.get('closure_end_date'));
            Date rangeEnd = (endDate != null && endDate >= startDate) ? endDate : startDate;
            // Shared fields across every day in the range
            String closureType    = toStr(m.get('closure_type'));
            String closureReason  = toStr(m.get('closure_reason'));
            Decimal hoursMissed   = toDecimal(m.get('hours_missed'));
            String makeUpMethod   = toStr(m.get('make_up_method'));
            Integer elearningDay  = toInteger(m.get('elearning_day_number'));
            Date schedMakeup      = toDate(m.get('scheduled_makeup_date'));
            // Expand: one DateEntry per calendar day from startDate to rangeEnd (inclusive)
            Date current = startDate;
            while (current <= rangeEnd) {
                DateEntry de = new DateEntry();
                de.closureDate         = current;
                de.closureType         = closureType;
                de.closureReason       = closureReason;
                de.hoursMissed         = hoursMissed;
                de.makeUpMethod        = makeUpMethod;
                de.elearningDayNumber  = elearningDay;
                de.scheduledMakeupDate = schedMakeup;
                result.add(de);
                current = current.addDays(1);
            }
        }
        return result;
    }

    private static String toStr(Object o) {
        if (o == null) {
            return null;
        }
        String s = String.valueOf(o);
        return String.isBlank(s) ? null : s;
    }

    private static Date toDate(Object o) {
        if (o == null) {
            return null;
        }
        String s = String.valueOf(o).trim();
        if (String.isBlank(s)) {
            return null;
        }
        try {
            // handles 'yyyy-MM-dd' and ISO datetime like 'yyyy-MM-ddThh:mm:ss'
            return Date.valueOf(s.length() >= 10 ? s.substring(0, 10) : s);
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal toDecimal(Object o) {
        if (o == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(o));
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer toInteger(Object o) {
        if (o == null) {
            return null;
        }
        try {
            return Integer.valueOf(String.valueOf(o));
        } catch (Exception e) {
            Decimal d = toDecimal(o); // tolerate "2.0"
            return d == null ? null : d.intValue();
        }
    }

    /**
     * For every affected school/year, if YTD missed instructional days now exceed the Tier 2
     * threshold AND no waiver exists yet, create a Draft Closure_Waiver_Request Case, link the
     * make-up-required events, stamp Waiver_Request_Case__c (dedup marker), and notify the contact.
     */
    private static void checkTierBoundaries(Set<Id> schoolIds) {
        if (schoolIds.isEmpty()) {
            return;
        }

        Compliance_Rules__mdt rules = Compliance_Rules__mdt.getInstance('Default');
        Decimal hoursPerDay = (rules != null && rules.Hours_Per_Instructional_Day__c != null
                && rules.Hours_Per_Instructional_Day__c != 0)
            ? rules.Hours_Per_Instructional_Day__c : 6.5;
        Decimal tier2 = (rules != null && rules.Tier2_Threshold__c != null) ? rules.Tier2_Threshold__c : 3;

        // Aggregate qualifying events per school/year
        Map<String, Decimal> hoursByKey = new Map<String, Decimal>();
        Map<String, Id> districtByKey = new Map<String, Id>();
        Map<String, Id> contactByKey = new Map<String, Id>();
        Map<String, List<Id>> eventIdsByKey = new Map<String, List<Id>>();
        Set<String> keysWithWaiver = new Set<String>();

        for (Closure_Event__c e : [
            SELECT Id, School__c, District__c, School_Year__c, Hours_Missed__c,
                   Reported_By__c, Waiver_Request_Case__c
            FROM Closure_Event__c
            WHERE School__c IN :schoolIds
            AND Instructional_Day__c = true
            AND Make_Up_Required__c = true
        ]) {
            String key = e.School__c + '|' + e.School_Year__c;
            hoursByKey.put(key, (hoursByKey.containsKey(key) ? hoursByKey.get(key) : 0)
                + (e.Hours_Missed__c == null ? 0 : e.Hours_Missed__c));
            districtByKey.put(key, e.District__c);
            if (e.Reported_By__c != null && !contactByKey.containsKey(key)) {
                contactByKey.put(key, e.Reported_By__c);
            }
            if (!eventIdsByKey.containsKey(key)) {
                eventIdsByKey.put(key, new List<Id>());
            }
            eventIdsByKey.get(key).add(e.Id);
            if (e.Waiver_Request_Case__c != null) {
                keysWithWaiver.add(key); // a waiver already covers this school/year
            }
        }

        Id waiverRtId = Case.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('Closure_Waiver_Request').getRecordTypeId();
        List<Group> queues = [
            SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'SCDE_Closures_Compliance' LIMIT 1
        ];
        Id queueId = queues.isEmpty() ? null : queues[0].Id;

        List<Case> newWaivers = new List<Case>();
        List<String> keysCreated = new List<String>();
        for (String key : hoursByKey.keySet()) {
            if (keysWithWaiver.contains(key)) {
                continue;
            }
            Decimal days = hoursByKey.get(key) / hoursPerDay;
            if (days > tier2) {
                Case w = new Case(
                    RecordTypeId = waiverRtId,
                    Status = 'New',
                    Waiver_Status__c = 'Draft',
                    Waiver_District__c = districtByKey.get(key),
                    Total_Missed_Days__c = days.setScale(1, System.RoundingMode.HALF_UP)
                );
                if (queueId != null) {
                    w.OwnerId = queueId;
                }
                newWaivers.add(w);
                keysCreated.add(key);
            }
        }

        if (newWaivers.isEmpty()) {
            return;
        }
        insert newWaivers;

        // Link events to their waiver + stamp Waiver_Request_Case__c (dedup marker for next time)
        List<Waiver_Closure_Link__c> links = new List<Waiver_Closure_Link__c>();
        List<Closure_Event__c> eventStamps = new List<Closure_Event__c>();
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        Map<Id, String> contactEmail = new Map<Id, String>();
        Set<Id> contactIds = new Set<Id>();
        for (String key : keysCreated) {
            if (contactByKey.containsKey(key)) {
                contactIds.add(contactByKey.get(key));
            }
        }
        if (!contactIds.isEmpty()) {
            for (Contact ct : [SELECT Id, Email FROM Contact WHERE Id IN :contactIds AND Email != null]) {
                contactEmail.put(ct.Id, ct.Email);
            }
        }

        for (Integer i = 0; i < keysCreated.size(); i++) {
            String key = keysCreated[i];
            Id caseId = newWaivers[i].Id;
            for (Id evId : eventIdsByKey.get(key)) {
                links.add(new Waiver_Closure_Link__c(Waiver_Case__c = caseId, Closure_Event__c = evId));
                eventStamps.add(new Closure_Event__c(Id = evId, Waiver_Request_Case__c = caseId));
            }
            Id contactId = contactByKey.get(key);
            if (contactId != null && contactEmail.containsKey(contactId)) {
                Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
                m.setToAddresses(new List<String>{ contactEmail.get(contactId) });
                m.setSubject('Waiver Case Created — Review Required in Member Center');
                m.setPlainTextBody('A school closure has pushed your district across a waiver tier '
                    + 'boundary. A Waiver Case has been created in Draft status. Please log in to '
                    + 'Member Center to review and complete the waiver request.');
                m.setSaveAsActivity(false);
                emails.add(m);
            }
        }

        if (!links.isEmpty()) {
            insert links;
        }
        if (!eventStamps.isEmpty()) {
            update eventStamps;
        }
        if (!emails.isEmpty()) {
            try {
                Messaging.sendEmail(emails);
            } catch (Exception e) {
                // email deliverability is org-config dependent (sandboxes often restrict it);
                // do not fail the transaction if notification can't be sent
            }
        }
    }

    private static String keyOf(Id schoolId, Date d) {
        return schoolId + '|' + d.year() + '-' + d.month() + '-' + d.day();
    }
}