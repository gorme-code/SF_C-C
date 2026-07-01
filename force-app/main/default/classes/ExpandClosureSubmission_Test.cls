@isTest
private class ExpandClosureSubmission_Test {

    @testSetup
    static void setup() {
        Id districtRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('District').getRecordTypeId();
        Id schoolRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('School').getRecordTypeId();

        Account dist = new Account(Name = 'Test District', RecordTypeId = districtRt);
        insert dist;
        insert new List<Account>{
            new Account(Name = 'Test School A', ParentId = dist.Id, RecordTypeId = schoolRt),
            new Account(Name = 'Test School B', ParentId = dist.Id, RecordTypeId = schoolRt)
        };
        insert new Contact(LastName = 'Reporter', AccountId = dist.Id, Email = 'reporter@example.com');
    }

    // ---- helpers -------------------------------------------------------------

    private static String isoDate(Integer y, Integer m, Integer d) {
        return y + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (d < 10 ? '0' + d : '' + d);
    }

    /** Build one date-entry map; nulls are omitted so JSON matches the API's optional-field shape. */
    private static Map<String, Object> entry(String dateStr, String type, String reason,
            Decimal hours, String method, Integer elearn, String schedMakeup) {
        Map<String, Object> e = new Map<String, Object>{
            'date' => dateStr,
            'closure_type' => type,
            'closure_reason' => reason
        };
        if (hours != null)       { e.put('hours_missed', hours); }
        if (method != null)      { e.put('make_up_method', method); }
        if (elearn != null)      { e.put('elearning_day_number', elearn); }
        if (schedMakeup != null) { e.put('scheduled_makeup_date', schedMakeup); }
        return e;
    }

    private static Id newSubmission(String scope, String affectedIds, Id districtId,
            List<Map<String, Object>> entries, String comments, Id contactId) {
        Id subRt = Case.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('Closure_Submission').getRecordTypeId();
        // Submission_Status = Returned so the Create_Closure_Events flow does NOT auto-fire;
        // the test invokes the Apex directly and then asserts it sets the status to Acknowledged.
        Case c = new Case(
            RecordTypeId = subRt,
            Status = 'New',
            Submission_Status__c = 'Returned',
            Submission_Scope__c = scope,
            Submission_District__c = districtId,
            Affected_School_IDs__c = affectedIds,
            Closure_Date_Entries__c = JSON.serialize(entries),
            Submission_Comments__c = comments,
            Reported_By_Contact__c = contactId
        );
        insert c;
        return c.Id;
    }

    private static void runFor(Id caseId) {
        ExpandClosureSubmission.Request req = new ExpandClosureSubmission.Request();
        req.caseId = caseId;
        ExpandClosureSubmission.run(new List<ExpandClosureSubmission.Request>{ req });
    }

    // ---- tests ---------------------------------------------------------------

    // Step 7 Test 1 — single school, two entries with different types + per-entry fields.
    @isTest
    static void testSingleSchoolTwoEntries() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Account school = [SELECT Id FROM Account WHERE Name = 'Test School A' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            // entry 1: Closed + Scheduled Weather Makeup Day + scheduled date
            entry(isoDate(2026, 1, 5), 'Closed', 'Weather_Conditions', 6.5,
                  'Scheduled Weather Makeup Day', null, isoDate(2026, 6, 1)),
            // entry 2: Closed - eLearning + day number 2 (en-dash matches the picklist value)
            entry(isoDate(2026, 1, 6), 'Closed – eLearning', 'Weather_Conditions', 6.5,
                  null, 2, null)
        };

        Id caseId = newSubmission('Single_School', String.valueOf(school.Id), dist.Id,
            entries, 'Two-day closure note', ct.Id);

        Test.startTest();
        runFor(caseId);
        Test.stopTest();

        Map<Date, Closure_Event__c> byDate = new Map<Date, Closure_Event__c>();
        for (Closure_Event__c ev : [
            SELECT Closure_Date__c, Closure_Type__c, Make_Up_Method__c, Scheduled_Makeup_Date__c,
                   eLearning_Day_Number__c, Comments__c, Status__c, Hours_Missed__c
            FROM Closure_Event__c WHERE Source_Case__c = :caseId
        ]) {
            byDate.put(ev.Closure_Date__c, ev);
        }
        System.assertEquals(2, byDate.size(), 'two events, one per date entry');

        Closure_Event__c e1 = byDate.get(Date.newInstance(2026, 1, 5));
        System.assertEquals('Scheduled Weather Makeup Day', e1.Make_Up_Method__c, 'method carried');
        System.assertEquals(Date.newInstance(2026, 6, 1), e1.Scheduled_Makeup_Date__c, 'scheduled makeup date carried');
        System.assertEquals(null, e1.eLearning_Day_Number__c, 'no eLearning number on the scheduled-makeup entry');
        System.assertEquals('Two-day closure note', e1.Comments__c, 'submission comments copied to event');
        System.assertEquals('Submitted', e1.Status__c, 'status Submitted');

        Closure_Event__c e2 = byDate.get(Date.newInstance(2026, 1, 6));
        System.assertEquals('Closed – eLearning', e2.Closure_Type__c, 'eLearning type carried');
        System.assertEquals('2', e2.eLearning_Day_Number__c, 'eLearning day number carried as text');
        System.assertEquals(null, e2.Make_Up_Method__c, 'no make-up method on the eLearning entry');

        System.assertEquals('Acknowledged',
            [SELECT Submission_Status__c FROM Case WHERE Id = :caseId].Submission_Status__c,
            'Case acknowledged');
    }

    // Step 7 Test 2 — District_Wide, per-school expansion + tier-boundary waiver creation.
    @isTest
    static void testDistrictWideExpansionAndTier() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        // 4 date entries, district-wide (2 schools) -> 2 x 4 = 8 events; each school crosses Tier 2
        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        for (Integer d = 2; d <= 5; d++) {
            entries.add(entry(isoDate(2026, 2, d), 'Closed', 'Weather_Conditions', 6.5, null, null, null));
        }

        Id caseId = newSubmission('District_Wide', null, dist.Id, entries, null, ct.Id);

        Test.startTest();
        runFor(caseId);
        Test.stopTest();

        System.assertEquals(8, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :caseId],
            '2 schools x 4 date entries');

        List<Case> waivers = [
            SELECT Id, Waiver_Status__c, Total_Missed_Days__c, Tier__c
            FROM Case WHERE RecordType.DeveloperName = 'Closure_Waiver_Request'
        ];
        System.assertEquals(2, waivers.size(), 'one waiver per crossing school');
        for (Case w : waivers) {
            System.assertEquals('Draft', w.Waiver_Status__c, 'waiver is Draft');
            System.assert(w.Total_Missed_Days__c > 3, 'Total_Missed_Days exceeds Tier 2 threshold');
            System.assertEquals('Tier 2', w.Tier__c, '4 days resolves to Tier 2');
        }
        System.assert([SELECT COUNT() FROM Waiver_Closure_Link__c] >= 8, 'events linked to waivers');
        System.assert([SELECT COUNT() FROM Closure_Event__c WHERE Waiver_Request_Case__c != null] >= 8,
            'events stamped with their waiver case');
    }

    // Step 7 Test 3 — multiple-schools parse + duplicate (school x date) skip on re-submit.
    @isTest
    static void testMultipleSchoolsAndDuplicateSkip() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Account a = [SELECT Id FROM Account WHERE Name = 'Test School A' LIMIT 1];
        Account b = [SELECT Id FROM Account WHERE Name = 'Test School B' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        Test.startTest();
        // Multiple schools, single date entry -> 2 events
        Id case1 = newSubmission('Multiple_Schools', a.Id + ',' + b.Id, dist.Id,
            new List<Map<String, Object>>{
                entry(isoDate(2026, 3, 2), 'Closed', 'Road_Conditions', 6.5, null, null, null)
            }, null, ct.Id);
        runFor(case1);
        System.assertEquals(2, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :case1],
            'two schools parsed from comma list');

        // Re-submit the same school/date -> duplicate skipped
        Id case2 = newSubmission('Single_School', String.valueOf(a.Id), dist.Id,
            new List<Map<String, Object>>{
                entry(isoDate(2026, 3, 2), 'Closed', 'Road_Conditions', 6.5, null, null, null)
            }, null, ct.Id);
        runFor(case2);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :case2],
            'no new event created for an existing school/date');
        System.assertEquals(1,
            [SELECT COUNT() FROM Closure_Event__c
             WHERE School__c = :a.Id AND Closure_Date__c = 2026-03-02],
            'still exactly one event for that school/date');
    }

    // Guard — malformed/empty JSON must not create events but must still acknowledge the Case.
    @isTest
    static void testEmptyEntriesAcknowledgesCase() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Account school = [SELECT Id FROM Account WHERE Name = 'Test School A' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        Id caseId = newSubmission('Single_School', String.valueOf(school.Id), dist.Id,
            new List<Map<String, Object>>(), null, ct.Id);

        Test.startTest();
        runFor(caseId);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :caseId],
            'no entries -> no events');
        System.assertEquals('Acknowledged',
            [SELECT Submission_Status__c FROM Case WHERE Id = :caseId].Submission_Status__c,
            'Case still acknowledged even with no entries');
    }
}
