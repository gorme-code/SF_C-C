public with sharing class KanbanQueueController {

    public class KanbanItem {
        @AuraEnabled public String workItemId;
        @AuraEnabled public String recordId;
        @AuraEnabled public String type;        // 'closure' | 'makeup' | 'waiver'
        @AuraEnabled public String column;      // 'todo' | 'done'
        @AuraEnabled public String title;
        @AuraEnabled public String caseNumber;
        @AuraEnabled public String tier;
        @AuraEnabled public String status;
        @AuraEnabled public String dateLabel;
        @AuraEnabled public String reason;
        @AuraEnabled public String scope;
        @AuraEnabled public Boolean isUrgent;
        @AuraEnabled public String approvedDate;
    }

    @AuraEnabled(cacheable=false)
    public static List<KanbanItem> getQueueItems() {
        List<Group> queues = [
            SELECT Id FROM Group
            WHERE Type = 'Queue' AND DeveloperName = 'SCDE_Closures_Compliance'
            LIMIT 1
        ];
        if (queues.isEmpty()) {
            return new List<KanbanItem>();
        }
        Id queueId = queues[0].Id;

        // Items currently sitting in the approval queue
        List<ProcessInstanceWorkitem> workItems = [
            SELECT Id, ProcessInstance.TargetObjectId
            FROM ProcessInstanceWorkitem
            WHERE ActorId = :queueId
            AND ProcessInstance.Status = 'Pending'
        ];

        Set<Id> caseIds    = new Set<Id>();
        Set<Id> makeupIds  = new Set<Id>();
        Map<Id, Id> workItemByRecord = new Map<Id, Id>(); // recordId -> workitemId

        for (ProcessInstanceWorkitem wi : workItems) {
            Id targetId = wi.ProcessInstance.TargetObjectId;
            workItemByRecord.put(targetId, wi.Id);
            if (targetId.getSObjectType() == Case.SObjectType) {
                caseIds.add(targetId);
            } else if (targetId.getSObjectType() == Makeup_Day__c.SObjectType) {
                makeupIds.add(targetId);
            }
        }

        List<KanbanItem> items = new List<KanbanItem>();

        // ── Pending Cases (Closure Submissions + Waivers) ──────────────────
        if (!caseIds.isEmpty()) {
            for (Case c : [
                SELECT Id, CaseNumber, RecordType.DeveloperName,
                       Account.Name,
                       Submission_Status__c, Waiver_Status__c,
                       Tier__c, Total_Missed_Days__c,
                       Closure_Start_Date__c, Closure_End_Date__c,
                       Closure_Reason__c, Submission_Scope__c,
                       CreatedDate
                FROM Case
                WHERE Id IN :caseIds
                ORDER BY CreatedDate ASC
            ]) {
                KanbanItem item = new KanbanItem();
                item.recordId    = c.Id;
                item.workItemId  = workItemByRecord.get(c.Id);
                item.caseNumber  = c.CaseNumber;
                item.column      = 'todo';
                item.title       = c.Account != null ? c.Account.Name : '—';

                if (c.RecordType.DeveloperName == 'Closure_Submission') {
                    item.type   = 'closure';
                    item.status = c.Submission_Status__c;
                    item.reason = c.Closure_Reason__c;
                    item.scope  = c.Submission_Scope__c;
                    item.tier   = c.Tier__c;
                    item.isUrgent = (c.Tier__c == 'Tier 3' || c.Tier__c == 'Tier 4');
                    if (c.Closure_Start_Date__c != null) {
                        item.dateLabel = c.Closure_Start_Date__c.format();
                        if (c.Closure_End_Date__c != null
                                && c.Closure_End_Date__c != c.Closure_Start_Date__c) {
                            item.dateLabel += ' – ' + c.Closure_End_Date__c.format();
                        }
                    }
                } else {
                    item.type   = 'waiver';
                    item.status = c.Waiver_Status__c;
                    item.tier   = c.Tier__c;
                    item.isUrgent = (c.Tier__c == 'Tier 3' || c.Tier__c == 'Tier 4');
                    item.dateLabel = c.Total_Missed_Days__c != null
                        ? String.valueOf(c.Total_Missed_Days__c.intValue()) + ' missed days'
                        : '';
                }
                items.add(item);
            }
        }

        // ── Pending Makeup Days ────────────────────────────────────────────
        if (!makeupIds.isEmpty()) {
            for (Makeup_Day__c m : [
                SELECT Id, Name, District__r.Name, School__r.Name,
                       Status__c, Method__c, Makeup_Date__c, CreatedDate
                FROM Makeup_Day__c
                WHERE Id IN :makeupIds
                ORDER BY CreatedDate ASC
            ]) {
                KanbanItem item = new KanbanItem();
                item.recordId   = m.Id;
                item.workItemId = workItemByRecord.get(m.Id);
                item.caseNumber = m.Name;
                item.type       = 'makeup';
                item.column     = 'todo';
                item.status     = m.Status__c;
                item.isUrgent   = false;
                item.title      = m.District__r != null ? m.District__r.Name
                                : (m.School__r  != null ? m.School__r.Name : '—');
                item.dateLabel  = m.Makeup_Date__c != null ? m.Makeup_Date__c.format() : '';
                item.reason     = m.Method__c;
                items.add(item);
            }
        }

        // ── Recently Approved (last 30 days) ──────────────────────────────
        Date cutoff = Date.today().addDays(-30);

        for (Case c : [
            SELECT Id, CaseNumber, RecordType.DeveloperName, Account.Name,
                   Submission_Status__c, Waiver_Status__c,
                   Tier__c, Approval_Decision_Date__c
            FROM Case
            WHERE (
                (RecordType.DeveloperName = 'Closure_Submission'
                    AND Submission_Status__c = 'Acknowledged')
                OR (RecordType.DeveloperName = 'Closure_Waiver_Request'
                    AND Waiver_Status__c IN ('Local_Board_Approved', 'State_Board_Approved'))
            )
            AND LastModifiedDate >= :cutoff
            ORDER BY LastModifiedDate DESC
            LIMIT 25
        ]) {
            KanbanItem item = new KanbanItem();
            item.recordId    = c.Id;
            item.caseNumber  = c.CaseNumber;
            item.column      = 'done';
            item.title       = c.Account != null ? c.Account.Name : '—';
            item.tier        = c.Tier__c;
            item.isUrgent    = false;
            item.approvedDate = c.Approval_Decision_Date__c != null
                ? c.Approval_Decision_Date__c.format() : '';

            if (c.RecordType.DeveloperName == 'Closure_Submission') {
                item.type   = 'closure';
                item.status = 'Approved';
            } else {
                item.type   = 'waiver';
                item.status = 'Approved';
            }
            items.add(item);
        }

        for (Makeup_Day__c m : [
            SELECT Id, Name, District__r.Name, Status__c, Method__c, Makeup_Date__c
            FROM Makeup_Day__c
            WHERE Status__c = 'Approved'
            AND LastModifiedDate >= :cutoff
            ORDER BY LastModifiedDate DESC
            LIMIT 10
        ]) {
            KanbanItem item = new KanbanItem();
            item.recordId   = m.Id;
            item.caseNumber = m.Name;
            item.type       = 'makeup';
            item.column     = 'done';
            item.status     = m.Status__c;
            item.isUrgent   = false;
            item.title      = m.District__r != null ? m.District__r.Name : '—';
            item.dateLabel  = m.Makeup_Date__c != null ? m.Makeup_Date__c.format() : '';
            item.reason     = m.Method__c;
            items.add(item);
        }

        return items;
    }

    @AuraEnabled
    public static void processApproval(String workItemId, String action, String comments) {
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setWorkitemId(workItemId);
        req.setAction(action); // 'Approve' or 'Reject'
        if (String.isNotBlank(comments)) {
            req.setComments(comments);
        }
        Approval.process(req);
    }
}
