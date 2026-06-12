/**
 * Invocable Apex called by the Create_Closure_Events flow (after insert on a
 * Closure_Submission Case). Expands one submission into N Closure_Event__c rows
 * (one per affected school per date), skipping duplicates, then acknowledges the Case.
 *
 * District__c is intentionally NOT set here — the before-save flow
 * Populate_District_On_Event derives it from the School's parent Account.
 */
public with sharing class ExpandClosureSubmission {

    public class Request {
        @InvocableVariable(label='Case Id' required=true)
        public Id caseId;
    }

    @InvocableMethod(label='Expand Closure Submission' description='Creates Closure_Event__c rows from a Closure Submission Case and sets the Case to Acknowledged.')
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
                   Closure_Start_Date__c, Closure_End_Date__c, Closure_Reason__c, Closure_Type__c,
                   Hours_Missed_Per_Day__c, Reported_By_Contact__c, Submission_Status__c
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

        // 1b/2. Resolve schools + build date lists per case
        Map<Id, List<Id>> schoolsByCase = new Map<Id, List<Id>>();
        Map<Id, List<Date>> datesByCase = new Map<Id, List<Date>>();
        Set<Id> allSchoolIds = new Set<Id>();
        Date minDate;
        Date maxDate;

        for (Case c : cases) {
            List<Id> schoolIds = new List<Id>();
            if (c.Submission_Scope__c == 'District_Wide') {
                if (schoolsByDistrict.containsKey(c.Submission_District__c)) {
                    schoolIds.addAll(schoolsByDistrict.get(c.Submission_District__c));
                }
            } else {
                // Single_School or Multiple_Schools: parse Affected_School_IDs__c
                if (String.isNotBlank(c.Affected_School_IDs__c)) {
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
            }
            schoolsByCase.put(c.Id, schoolIds);
            allSchoolIds.addAll(schoolIds);

            List<Date> dates = new List<Date>();
            if (c.Closure_Start_Date__c != null && c.Closure_End_Date__c != null) {
                Date d = c.Closure_Start_Date__c;
                Integer guard = 0;
                while (d <= c.Closure_End_Date__c && guard < 1000) {
                    dates.add(d);
                    d = d.addDays(1);
                    guard++;
                }
            } else if (c.Closure_Start_Date__c != null) {
                dates.add(c.Closure_Start_Date__c);
            }
            datesByCase.put(c.Id, dates);

            for (Date dd : dates) {
                if (minDate == null || dd < minDate) { minDate = dd; }
                if (maxDate == null || dd > maxDate) { maxDate = dd; }
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

        // 3b. Build new events (skip existing + intra-batch duplicates)
        List<Closure_Event__c> toCreate = new List<Closure_Event__c>();
        Set<String> plannedKeys = new Set<String>();
        Datetime nowTs = Datetime.now();
        for (Case c : cases) {
            List<Id> schoolIds = schoolsByCase.get(c.Id);
            List<Date> dates = datesByCase.get(c.Id);
            if (schoolIds == null || dates == null) {
                continue;
            }
            for (Id sid : schoolIds) {
                for (Date dt : dates) {
                    String key = keyOf(sid, dt);
                    if (existingKeys.contains(key) || plannedKeys.contains(key)) {
                        continue;
                    }
                    plannedKeys.add(key);
                    toCreate.add(new Closure_Event__c(
                        School__c = sid,
                        Source_Case__c = c.Id,
                        Closure_Date__c = dt,
                        Closure_Reason__c = c.Closure_Reason__c,
                        Closure_Type__c = c.Closure_Type__c,
                        Hours_Missed__c = c.Hours_Missed_Per_Day__c,
                        Reported_By__c = c.Reported_By_Contact__c,
                        Reported_Date__c = nowTs,
                        Status__c = 'Submitted'
                    ));
                }
            }
        }

        if (!toCreate.isEmpty()) {
            insert toCreate;
        }

        // 4. Acknowledge the cases
        List<Case> toUpdate = new List<Case>();
        for (Case c : cases) {
            toUpdate.add(new Case(Id = c.Id, Submission_Status__c = 'Acknowledged'));
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    private static String keyOf(Id schoolId, Date d) {
        return schoolId + '|' + d.year() + '-' + d.month() + '-' + d.day();
    }
}
