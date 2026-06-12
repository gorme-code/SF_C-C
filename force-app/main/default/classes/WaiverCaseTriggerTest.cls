@isTest
private class WaiverCaseTriggerTest {

    private static Id waiverRtId() {
        return Case.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get('Closure_Waiver_Request')
            .getRecordTypeId();
    }

    @testSetup
    static void setup() {
        // Setup objects (Users / permission sets) isolated in runAs to avoid MIXED_DML
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile stdP = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Profile admP = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];

            User stdU = buildUser('wvrstd', stdP.Id);
            User admU = buildUser('wvradm', admP.Id);
            insert new List<User>{ stdU, admU };

            // Grant the standard user Delete on Case WITHOUT Modify All Data
            PermissionSet ps = new PermissionSet(Name = 'Waiver_Delete_Test', Label = 'Waiver Delete Test');
            insert ps;
            insert new ObjectPermissions(
                ParentId = ps.Id,
                SobjectType = 'Case',
                PermissionsRead = true,
                PermissionsCreate = true,
                PermissionsEdit = true,
                PermissionsDelete = true
            );
            insert new PermissionSetAssignment(AssigneeId = stdU.Id, PermissionSetId = ps.Id);
        }
    }

    private static User buildUser(String tag, Id profileId) {
        String uniq = tag + String.valueOf(System.now().getTime());
        return new User(
            FirstName = 'CC',
            LastName = tag,
            Alias = tag.left(8),
            Username = uniq + '@cctest.example.com.invalid',
            Email = uniq + '@cctest.example.com',
            CommunityNickname = uniq.left(40),
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = profileId
        );
    }

    private static User getUser(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName ORDER BY CreatedDate DESC LIMIT 1];
    }

    @isTest
    static void testStandardUserCannotDeleteWaiver() {
        User stdU = getUser('wvrstd');

        // Owned by the standard user so record-level delete reaches the trigger.
        // Waiver_Status left at default (Draft) so the Route_Waiver_By_Tier flow does not fire.
        Case c = new Case(
            RecordTypeId = waiverRtId(),
            Status = 'New',
            Subject = 'Test Waiver',
            OwnerId = stdU.Id
        );
        insert c;

        Test.startTest();
        System.runAs(stdU) {
            try {
                delete c;
                System.assert(false, 'Delete should have been blocked for a non-Modify-All user.');
            } catch (DmlException e) {
                System.assert(
                    e.getMessage().contains('cannot be deleted'),
                    'Unexpected error message: ' + e.getMessage()
                );
            }
        }
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Case WHERE Id = :c.Id],
            'Waiver Case should still exist after the blocked delete.'
        );
    }

    @isTest
    static void testAdminCanDeleteWaiver() {
        User admU = getUser('wvradm');

        Case c = new Case(
            RecordTypeId = waiverRtId(),
            Status = 'New',
            Subject = 'Test Waiver 2'
        );
        insert c;

        Test.startTest();
        System.runAs(admU) {
            delete c; // System Administrator has Modify All Data -> trigger allows
        }
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Case WHERE Id = :c.Id],
            'Admin with Modify All Data should be able to delete the Waiver Case.'
        );
    }
}
