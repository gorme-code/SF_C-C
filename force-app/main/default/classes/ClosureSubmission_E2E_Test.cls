/**
 * Salesforce end-to-end test (v1.3 Build Guide Step 9). Inserts Closure_Submission Cases with
 * Submission_Status = 'Submitted' so the real Create_Closure_Events flow fires -> ExpandClosureSubmission
 * -> Set_Make_Up_Required, exercising the full submission pipeline (not a direct Apex call).
 */
@isTest
private class ClosureSubmission_E2E_Test {

    @testSetup
    static void setup() {
        Id districtRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('District').getRecordTypeId();
        Id schoolRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('School').getRecordTypeId();

        Account dist = new Account(Name = 'E2E District', RecordTypeId = districtRt);
        insert dist;
        List<Account> schools = new List<Account>();
        for (Integer i = 1; i <= 4; i++) {
            schools.add(new Account(Name = 'E2E School ' + i, ParentId = dist.Id, RecordTypeId = schoolRt));
        }
        insert schools;
        insert new Contact(LastName = 'E2E Reporter', AccountId = dist.Id, Email = 'e2e@example.com');
    }

    // ---- helpers -------------------------------------------------------------

    private static String isoDate(Integer y, Integer m, Integer d) {
        return y + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (d < 10 ? '0' + d : '' + d);
    }

    private static Map<String, Object> entry(String dateStr, String type, String reason,
            Decimal hours, String method, Integer elearn, String schedMakeup) {
        Map<String, Object> e = new Map<String, Object>{
            'date' => dateStr, 'closure_type' => type, 'closure_reason' => reason
        };
        if (hours != null)       { e.put('hours_missed', hours); }
        if (method != null)      { e.put('make_up_method', method); }
        if (elearn != null)      { e.put('elearning_day_number', elearn); }
        if (schedMakeup != null) { e.put('scheduled_makeup_date', schedMakeup); }
        return e;
    }

    private static Id submitCase(String scope, String affectedIds, Id districtId,
            List<Map<String, Object>> entries, String comments) {
        Id subRt = Case.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('Closure_Submission').getRecordTypeId();
        Contact ct = [SELECT Id FROM Contact WHERE LastName = 'E2E Reporter' LIMIT 1];
        Case c = new Case(
            RecordTypeId = subRt,
            Status = 'New',
            Submission_Status__c = 'Submitted',   // fires Create_Closure_Events end-to-end
            Submission_Scope__c = scope,
            Submission_District__c = districtId,
            Affected_School_IDs__c = affectedIds,
            Closure_Date_Entries__c = JSON.serialize(entries),
            Submission_Comments__c = comments,
            Reported_By_Contact__c = ct.Id
        );
        insert c;
        return c.Id;
    }

    private static Id districtId() {
        return [SELECT Id FROM Account WHERE Name = 'E2E District' LIMIT 1].Id;
    }

    private static Id schoolId(Integer n) {
        return [SELECT Id FROM Account WHERE Name = :('E2E School ' + n) LIMIT 1].Id;
    }

    // ---- tests ---------------------------------------------------------------

    // Row 1 — single school, 3 entries (Closed / eLearning / Delayed)
    @isTest
    static void testThreeMixedEntriesSingleSchool() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            entry(isoDate(2026, 1, 5), 'Closed', 'Weather_Conditions', 6.5, null, null, null),
            entry(isoDate(2026, 1, 6), 'Closed – eLearning', 'Weather_Conditions', 6.5, null, 2, null),
            entry(isoDate(2026, 1, 7), 'Delayed', 'Weather_Conditions', 6.5, null, null, null)
        };
        Id caseId;
        Test.startTest();
        caseId = submitCase('Single_School', String.valueOf(schoolId(1)), districtId(), entries, null);
        Test.stopTest();

        Map<String, Closure_Event__c> byType = new Map<String, Closure_Event__c>();
        for (Closure_Event__c ev : [
            SELECT Closure_Type__c, Make_Up_Required__c, eLearning_Day_Number__c
            FROM Closure_Event__c WHERE Source_Case__c = :caseId
        ]) {
            byType.put(ev.Closure_Type__c, ev);
        }
        System.assertEquals(3, byType.size(), '3 events, one per entry');
        System.assertEquals(true, byType.get('Closed').Make_Up_Required__c,
            'Closed + makeup reason + no method => makeup required');
        System.assertEquals(false, byType.get('Closed – eLearning').Make_Up_Required__c,
            'eLearning => no makeup');
        System.assertEquals('2', byType.get('Closed – eLearning').eLearning_Day_Number__c,
            'eLearning day number set');
        System.assertEquals(false, byType.get('Delayed').Make_Up_Required__c, 'Delayed => no makeup');

        System.assertEquals('Acknowledged',
            [SELECT Submission_Status__c FROM Case WHERE Id = :caseId].Submission_Status__c);
    }

    // Row 2 — District_Wide, 1 entry, 4 schools => 4 events
    @isTest
    static void testDistrictWideFourSchools() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            entry(isoDate(2026, 1, 20), 'Closed', 'Road_Conditions', 6.5, null, null, null)
        };
        Id caseId;
        Test.startTest();
        caseId = submitCase('District_Wide', null, districtId(), entries, null);
        Test.stopTest();

        List<Closure_Event__c> evs = [
            SELECT School__c, Closure_Reason__c, Closure_Type__c, Hours_Missed__c, Closure_Date__c
            FROM Closure_Event__c WHERE Source_Case__c = :caseId
        ];
        System.assertEquals(4, evs.size(), 'one event per school in the district');
        Set<Id> schoolsSeen = new Set<Id>();
        for (Closure_Event__c ev : evs) {
            schoolsSeen.add(ev.School__c);
            System.assertEquals('Road_Conditions', ev.Closure_Reason__c, 'entry reason applied');
            System.assertEquals(6.5, ev.Hours_Missed__c, 'entry hours applied');
            System.assertEquals(Date.newInstance(2026, 1, 20), ev.Closure_Date__c, 'entry date applied');
        }
        System.assertEquals(4, schoolsSeen.size(), 'four distinct schools');
    }

    // Row 3 — Scheduled Weather Makeup Day + date => Scheduled_Makeup_Date set, no makeup required
    @isTest
    static void testScheduledMakeupDateInline() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            entry(isoDate(2026, 1, 22), 'Closed', 'Weather_Conditions', 6.5,
                  'Scheduled Weather Makeup Day', null, isoDate(2026, 6, 1))
        };
        Id caseId;
        Test.startTest();
        caseId = submitCase('Single_School', String.valueOf(schoolId(2)), districtId(), entries, null);
        Test.stopTest();

        Closure_Event__c ev = [
            SELECT Make_Up_Method__c, Scheduled_Makeup_Date__c, Make_Up_Required__c
            FROM Closure_Event__c WHERE Source_Case__c = :caseId LIMIT 1
        ];
        System.assertEquals('Scheduled Weather Makeup Day', ev.Make_Up_Method__c);
        System.assertEquals(Date.newInstance(2026, 6, 1), ev.Scheduled_Makeup_Date__c, 'scheduled date populated');
        System.assertEquals(false, ev.Make_Up_Required__c, 'declared method => no makeup required');
    }

    // Row 4 — District School Board Waived Days 4-6 => saved, no makeup, no waiver auto-created
    @isTest
    static void testBoardWaivedIsInformationalOnly() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>{
            entry(isoDate(2026, 1, 23), 'Closed', 'Weather_Conditions', 6.5,
                  'District School Board Waived Days 4-6', null, null)
        };
        Id caseId;
        Test.startTest();
        caseId = submitCase('Single_School', String.valueOf(schoolId(3)), districtId(), entries, null);
        Test.stopTest();

        Closure_Event__c ev = [
            SELECT Make_Up_Method__c, Make_Up_Required__c
            FROM Closure_Event__c WHERE Source_Case__c = :caseId LIMIT 1
        ];
        System.assertEquals('District School Board Waived Days 4-6', ev.Make_Up_Method__c, 'event saved with method');
        System.assertEquals(false, ev.Make_Up_Required__c, 'board-waived => no makeup required');
        System.assertEquals(0,
            [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Closure_Waiver_Request'],
            'board-waived method does NOT auto-create a waiver (only YTD threshold does)');
    }

    // Row 5 — cross the Tier 2 threshold (>3 missed days) => Draft waiver + links auto-created
    @isTest
    static void testTierBoundaryAutoCreatesWaiver() {
        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        for (Integer d = 2; d <= 5; d++) { // 4 makeup-required days > Tier 2 (3)
            entries.add(entry(isoDate(2026, 2, d), 'Closed', 'Weather_Conditions', 6.5, null, null, null));
        }
        Id caseId;
        Test.startTest();
        caseId = submitCase('Single_School', String.valueOf(schoolId(4)), districtId(), entries, null);
        Test.stopTest();

        System.assertEquals(4, [SELECT COUNT() FROM Closure_Event__c WHERE Source_Case__c = :caseId],
            '4 events created');
        List<Case> waivers = [
            SELECT Waiver_Status__c, Total_Missed_Days__c, Tier__c
            FROM Case WHERE RecordType.DeveloperName = 'Closure_Waiver_Request'
        ];
        System.assertEquals(1, waivers.size(), 'one Draft waiver auto-created for the crossing school');
        System.assertEquals('Draft', waivers[0].Waiver_Status__c);
        System.assert(waivers[0].Total_Missed_Days__c > 3, 'exceeds Tier 2 threshold');
        System.assert([SELECT COUNT() FROM Waiver_Closure_Link__c] >= 4, 'events linked to the waiver');
        System.assert([SELECT COUNT() FROM Closure_Event__c WHERE Waiver_Request_Case__c != null] >= 4,
            'events stamped with the waiver case');
    }

    // Row 6 — new CMDT reason values active; old ones deactivated
    @isTest
    static void testCmdtReasonsActive() {
        Set<String> activeNames = new Set<String>();
        for (Closure_Reason__mdt r : [SELECT DeveloperName FROM Closure_Reason__mdt WHERE Active__c = true]) {
            activeNames.add(r.DeveloperName);
        }
        for (String expected : new List<String>{
                'Environmental_Issues', 'Facility_Maintenance', 'Health_Safety_Concerns',
                'Honored_Remembrances', 'Other', 'Road_Conditions', 'Weather_Conditions'}) {
            System.assert(activeNames.contains(expected), 'new reason active: ' + expected);
        }
        for (String oldName : new List<String>{
                'Weather_Snow', 'Weather_Flooding', 'Weather_Hurricane', 'Infrastructure_Failure',
                'Safety_Threat', 'Staffing_Shortage', 'Other_Disruption'}) {
            System.assert(!activeNames.contains(oldName), 'old reason deactivated: ' + oldName);
        }
    }
}
