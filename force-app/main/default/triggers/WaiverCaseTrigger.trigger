/**
 * Blocks hard deletes of Closure_Waiver_Request Cases (long-lived compliance records).
 * Users with the "Modify All Data" system permission are allowed to delete.
 *
 * Trigger.old exposes RecordTypeId but not RecordType.DeveloperName, so the Waiver
 * record-type Id is resolved via Schema describe. ModifyAllData is checked via
 * PermissionSetAssignment (profile + assigned permission sets).
 */
trigger WaiverCaseTrigger on Case (before delete) {
    Schema.RecordTypeInfo rtInfo = Case.SObjectType.getDescribe()
        .getRecordTypeInfosByDeveloperName()
        .get('Closure_Waiver_Request');

    Boolean hasModifyAll = ![
        SELECT Id
        FROM PermissionSetAssignment
        WHERE AssigneeId = :UserInfo.getUserId()
        AND PermissionSet.PermissionsModifyAllData = true
        LIMIT 1
    ].isEmpty();

    if (rtInfo == null || hasModifyAll) {
        return;
    }

    Id waiverRtId = rtInfo.getRecordTypeId();
    for (Case c : Trigger.old) {
        if (c.RecordTypeId == waiverRtId) {
            c.addError('Waiver Request Cases cannot be deleted.');
        }
    }
}