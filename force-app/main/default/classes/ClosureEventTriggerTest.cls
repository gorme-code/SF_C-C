@isTest
private class ClosureEventTriggerTest {

    @testSetup
    static void setup() {
        // Non-setup data: a district + child school so the before-save flow can resolve District__c
        Account district = new Account(Name = 'CE Test District');
        insert district;
        Account school = new Account(Name = 'CE Test School', ParentId = district.Id);
        insert school;

        // Setup objects (Users / permission sets) must be isolated in runAs to avoid MIXED_DML
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile stdP = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            Profile admP = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];

            User stdU = buildUser('ccdelstd', stdP.Id);
            User admU = buildUser('ccdeladm', admP.Id);
            insert new List<User>{ stdU, admU };

            // Grant the standard user Delete on Closure_Event__c WITHOUT Modify All Data,
            // so the delete reaches the trigger instead of failing on object CRUD.
            PermissionSet ps = new PermissionSet(Name = 'CE_Delete_Test', Label = 'CE Delete Test');
            insert ps;
            insert new ObjectPermissions(
                ParentId = ps.Id,
                SobjectType = 'Closure_Event__c',
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
    static void testStandardUserCannotDelete() {
        Account school = [SELECT Id FROM Account WHERE Name = 'CE Test School' LIMIT 1];
        User stdU = getUser('ccdelstd');

        // Owned by the standard user so record-level delete is allowed and reaches the trigger
        Closure_Event__c ce = new Closure_Event__c(
            School__c = school.Id,
            Closure_Date__c = Date.today(),
            Instructional_Day__c = false,
            OwnerId = stdU.Id
        );
        insert ce;

        Test.startTest();
        System.runAs(stdU) {
            try {
                delete ce;
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
            [SELECT COUNT() FROM Closure_Event__c WHERE Id = :ce.Id],
            'Record should still exist after the blocked delete.'
        );
    }

    @isTest
    static void testAdminCanDelete() {
        Account school = [SELECT Id FROM Account WHERE Name = 'CE Test School' LIMIT 1];
        User admU = getUser('ccdeladm');

        Closure_Event__c ce = new Closure_Event__c(
            School__c = school.Id,
            Closure_Date__c = Date.today().addDays(1),
            Instructional_Day__c = false
        );
        insert ce;

        Test.startTest();
        System.runAs(admU) {
            delete ce; // System Administrator has Modify All Data -> trigger allows
        }
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Closure_Event__c WHERE Id = :ce.Id],
            'Admin with Modify All Data should be able to delete.'
        );
    }
}
