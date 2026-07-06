/**
 * Blocks hard deletes of Closure_Event__c (compliance records are never hard-deleted;
 * set Status__c = Cancelled instead). Users with the "Modify All Data" system permission
 * (admins / data cleanup) are allowed to delete.
 *
 * ModifyAllData is checked via PermissionSetAssignment (covers both the profile's own
 * permission set and any assigned permission sets) because neither
 * FeatureManagement.checkPermission (custom permissions only) nor UserInfo exposes it.
 */
trigger ClosureEventTrigger on Closure_Event__c (before delete) {
    Boolean hasModifyAll = ![
        SELECT Id
        FROM PermissionSetAssignment
        WHERE AssigneeId = :UserInfo.getUserId()
        AND PermissionSet.PermissionsModifyAllData = true
        LIMIT 1
    ].isEmpty();

    if (!hasModifyAll) {
        for (Closure_Event__c ce : Trigger.old) {
            ce.addError('Closure Event records cannot be deleted. Set Status to Cancelled instead.');
        }
    }
}