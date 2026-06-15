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

    private static Id newSubmission(String scope, String affectedIds, Id districtId,
            Date startDate, Date endDate, Id contactId) {
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
            Closure_Start_Date__c = startDate,
            Closure_End_Date__c = endDate,
            Closure_Reason__c = 'Weather_Snow',
            Closure_Type__c = 'Closed',
            Hours_Missed_Per_Day__c = 6.5,
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

    @isTest
    static void testSingleSchoolExpansion() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Account school = [SELECT Id FROM Account WHERE Name = 'Test School A' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        Id caseId = newSubmission('Single_School', String.valueOf(school.Id), dist.Id,
            Date.newInstance(2026, 1, 5), Date.newInstance(2026, 1, 5), ct.Id);

        Test.startTest();
        runFor(caseId);
        Test.stopTest();

        List<Closure_Event__c> evs = [
            SELECT Id, District__c, School__c, Status__c FROM Closure_Event__c WHERE Source_Case__c = :caseId
        ];
        System.assertEquals(1, evs.size(), 'one event for single school / single day');
        System.assertEquals(dist.Id, evs[0].District__c, 'District auto-populated from school parent');
        System.assertEquals(school.Id, evs[0].School__c, 'school set');
        System.assertEquals('Acknowledged',
            [SELECT Submission_Status__c FROM Case WHERE Id = :caseId].Submission_Status__c,
            'Case acknowledged');
    }

    @isTest
    static void testDistrictWideExpansionAndTier() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        // District-wide, 4-day range -> 2 schools x 4 days = 8 events; each school exceeds Tier 2
        Id caseId = newSubmission('District_Wide', null, dist.Id,
            Date.newInstance(2026, 2, 2), Date.newInstance(2026, 2, 5), ct.Id);

        Test.startTest();
        runFor(caseId);
        Test.stopTest();

        Integer eventCount = [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :caseId];
        System.assertEquals(8, eventCount, '2 schools x 4 dates');

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

    @isTest
    static void testMultipleSchoolsAndDuplicateSkip() {
        Account dist = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];
        Account a = [SELECT Id FROM Account WHERE Name = 'Test School A' LIMIT 1];
        Account b = [SELECT Id FROM Account WHERE Name = 'Test School B' LIMIT 1];
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'Reporter' LIMIT 1];

        Test.startTest();
        // Multiple schools, single date -> 2 events
        Id case1 = newSubmission('Multiple_Schools', a.Id + ',' + b.Id, dist.Id,
            Date.newInstance(2026, 3, 2), Date.newInstance(2026, 3, 2), ct.Id);
        runFor(case1);
        System.assertEquals(2, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :case1],
            'two schools parsed from comma list');

        // Re-submit the same school/date -> duplicate skipped
        Id case2 = newSubmission('Single_School', String.valueOf(a.Id), dist.Id,
            Date.newInstance(2026, 3, 2), Date.newInstance(2026, 3, 2), ct.Id);
        runFor(case2);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :case2],
            'no new event created for an existing school/date');
        System.assertEquals(1,
            [SELECT COUNT() FROM Closure_Event__c
             WHERE School__c = :a.Id AND Closure_Date__c = 2026-03-02],
            'still exactly one event for that school/date');
    }
}
