/**
 * Covers the Set_Make_Up_Required after-save flow on Closure_Event__c (v1.3 logic).
 * Inserts events and asserts Make_Up_Required__c after the flow runs.
 * Uses Weather_Conditions (Requires_Makeup_Default = true) as the makeup-required reason.
 */
@isTest
private class Set_Make_Up_Required_Test {

    @testSetup
    static void setup() {
        Id districtRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('District').getRecordTypeId();
        Id schoolRt = Account.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName().get('School').getRecordTypeId();

        Account dist = new Account(Name = 'MUR District', RecordTypeId = districtRt);
        insert dist;
        insert new Account(Name = 'MUR School', ParentId = dist.Id, RecordTypeId = schoolRt);
    }

    private static Id schoolId() {
        return [SELECT Id FROM Account WHERE Name = 'MUR School' LIMIT 1].Id;
    }

    /** Insert one event and return its post-flow Make_Up_Required__c. */
    private static Boolean makeUpRequiredFor(String type, String reason, String method,
            Boolean instructional, Date closureDate) {
        Closure_Event__c e = new Closure_Event__c(
            School__c = schoolId(),
            Closure_Date__c = closureDate,
            Closure_Type__c = type,
            Closure_Reason__c = reason,
            Make_Up_Method__c = method,
            Instructional_Day__c = instructional,
            Hours_Missed__c = 6.5,
            Status__c = 'Submitted'
        );
        insert e;
        return [SELECT Make_Up_Required__c FROM Closure_Event__c WHERE Id = :e.Id].Make_Up_Required__c;
    }

    // Step 8 Test 1 — eLearning type => false
    @isTest
    static void testELearningIsFalse() {
        Test.startTest();
        Boolean mur = makeUpRequiredFor('Closed – eLearning', 'Weather_Conditions', null,
            true, Date.newInstance(2026, 1, 6));
        Test.stopTest();
        System.assertEquals(false, mur, 'eLearning closures never require makeup');
    }

    // Step 8 Test 2 — Make_Up_Method populated => false (even for a makeup-required reason)
    @isTest
    static void testMethodPopulatedIsFalse() {
        Test.startTest();
        Boolean mur = makeUpRequiredFor('Closed', 'Weather_Conditions',
            'Additional Hours to the School Day', true, Date.newInstance(2026, 1, 7));
        Test.stopTest();
        System.assertEquals(false, mur, 'declared make-up method => makeup not required');
    }

    // Step 8 Test 3 — Delayed and Early Dismissal => false on both
    @isTest
    static void testDelayedAndEarlyDismissalAreFalse() {
        Test.startTest();
        Boolean delayed = makeUpRequiredFor('Delayed', 'Weather_Conditions', null,
            true, Date.newInstance(2026, 1, 8));
        Boolean earlyDismissal = makeUpRequiredFor('Early Dismissal', 'Weather_Conditions', null,
            true, Date.newInstance(2026, 1, 9));
        Test.stopTest();
        System.assertEquals(false, delayed, 'Delayed => no makeup');
        System.assertEquals(false, earlyDismissal, 'Early Dismissal => no makeup');
    }

    // Step 8 Test 4 — Closed + no method + makeup-required reason => true
    @isTest
    static void testStandardMakeupRequiredIsTrue() {
        Test.startTest();
        Boolean mur = makeUpRequiredFor('Closed', 'Weather_Conditions', null,
            true, Date.newInstance(2026, 1, 12));
        Test.stopTest();
        System.assertEquals(true, mur, 'Closed, no method, makeup-required reason => makeup required');
    }

    // Step 1 guard — non-instructional day => false regardless of reason
    @isTest
    static void testNonInstructionalIsFalse() {
        Test.startTest();
        Boolean mur = makeUpRequiredFor('Closed', 'Weather_Conditions', null,
            false, Date.newInstance(2026, 1, 13));
        Test.stopTest();
        System.assertEquals(false, mur, 'non-instructional day => no makeup');
    }
}
