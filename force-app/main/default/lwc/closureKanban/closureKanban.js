import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getQueueItems       from '@salesforce/apex/KanbanQueueController.getQueueItems';
import processApproval     from '@salesforce/apex/KanbanQueueController.processApproval';
import recallApprovedItem  from '@salesforce/apex/KanbanQueueController.recallApprovedItem';

export default class ClosureKanban extends LightningElement {

    // Board data
    todoCards = [];
    doneCards = [];
    isLoading = true;
    error     = null;

    // Modal state
    showModal     = false;
    pendingAction = null; // { workItemId, action }
    comments      = '';
    isProcessing  = false;

    // Filter state — all on by default
    activeFilters = { closure: true, makeup: true, waiver: true };

    connectedCallback() {
        this.loadCards();
    }

    loadCards() {
        this.isLoading = true;
        this.error     = null;
        getQueueItems()
            .then(data => {
                this.todoCards = data.filter(c => c.column === 'todo');
                this.doneCards = data.filter(c => c.column === 'done');
                this.isLoading = false;
            })
            .catch(err => {
                this.error     = err?.body?.message ?? 'Failed to load queue items.';
                this.isLoading = false;
            });
    }

    // ── Filtered lists ──────────────────────────────────────────────────
    get filteredTodo() { return this.todoCards.filter(c => this.activeFilters[c.type]); }
    get filteredDone() { return this.doneCards.filter(c => this.activeFilters[c.type]); }
    get todoCount()    { return this.filteredTodo.length; }
    get doneCount()    { return this.filteredDone.length; }
    get emptyTodo()    { return !this.isLoading && this.filteredTodo.length === 0; }
    get emptyDone()    { return !this.isLoading && this.filteredDone.length === 0; }
    get showBoard()    { return !this.isLoading && !this.error; }
    get hasError()     { return !this.isLoading && !!this.error; }

    // ── Summary stats ────────────────────────────────────────────────────
    get totalPending()        { return this.todoCards.length; }
    get urgentCount()         { return this.todoCards.filter(c => c.isUrgent).length; }
    get closurePendingCount() { return this.todoCards.filter(c => c.type === 'closure').length; }
    get makeupPendingCount()  { return this.todoCards.filter(c => c.type === 'makeup').length; }
    get waiverPendingCount()  { return this.todoCards.filter(c => c.type === 'waiver').length; }

    // ── Filter chips ─────────────────────────────────────────────────────
    toggleFilter(event) {
        const type = event.currentTarget.dataset.type;
        this.activeFilters = { ...this.activeFilters, [type]: !this.activeFilters[type] };
    }

    get closureFilterClass() { return 'filter-chip' + (this.activeFilters.closure ? ' active-closure' : ''); }
    get makeupFilterClass()  { return 'filter-chip' + (this.activeFilters.makeup  ? ' active-makeup'  : ''); }
    get waiverFilterClass()  { return 'filter-chip' + (this.activeFilters.waiver  ? ' active-waiver'  : ''); }

    // ── Card action events ────────────────────────────────────────────────
    handleApprove(event) { this.openModal(event.detail.workItemId, 'Approve'); }
    handleReturn(event)  { this.openModal(event.detail.workItemId, 'Reject');  }
    handleRecall(event)  {
        this.pendingAction = { recordId: event.detail.recordId, type: event.detail.type, action: 'Recall' };
        this.comments      = '';
        this.showModal     = true;
    }

    openModal(workItemId, action) {
        this.pendingAction = { workItemId, action };
        this.comments      = '';
        this.showModal     = true;
    }

    // ── Modal handlers ────────────────────────────────────────────────────
    handleCommentsChange(event) { this.comments = event.target.value; }

    handleModalCancel() {
        this.showModal     = false;
        this.pendingAction = null;
    }

    handleModalConfirm() {
        this.isProcessing = true;
        const isRecall = this.pendingAction.action === 'Recall';

        const apiCall = isRecall
            ? recallApprovedItem({
                recordId: this.pendingAction.recordId,
                type:     this.pendingAction.type,
                comments: this.comments
              })
            : processApproval({
                workItemId: this.pendingAction.workItemId,
                action:     this.pendingAction.action,
                comments:   this.comments
              });

        apiCall
            .then(() => {
                const label = isRecall ? 'recalled to review'
                    : (this.pendingAction.action === 'Approve' ? 'approved' : 'returned');
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Success',
                    message: `Record ${label} successfully.`,
                    variant: 'success'
                }));
                this.showModal     = false;
                this.pendingAction = null;
                this.isProcessing  = false;
                this.loadCards();
            })
            .catch(err => {
                this.isProcessing = false;
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Error',
                    message: err?.body?.message ?? 'Action failed. Please try again.',
                    variant: 'error',
                    mode:    'sticky'
                }));
            });
    }

    get modalTitle() {
        if (this.pendingAction?.action === 'Approve') return 'Confirm Approval';
        if (this.pendingAction?.action === 'Recall')  return 'Recall to To Do';
        return 'Confirm Return';
    }
    get confirmButtonLabel() {
        if (this.pendingAction?.action === 'Approve') return 'Approve';
        if (this.pendingAction?.action === 'Recall')  return 'Recall';
        return 'Return';
    }
    get confirmButtonVariant() {
        if (this.pendingAction?.action === 'Approve') return 'success';
        if (this.pendingAction?.action === 'Recall')  return 'brand';
        return 'destructive';
    }

    handleRefresh() { this.loadCards(); }
}
