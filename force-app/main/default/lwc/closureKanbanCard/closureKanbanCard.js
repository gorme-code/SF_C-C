import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

const TYPE_LABELS = { closure: 'Closure', makeup: 'Makeup', waiver: 'Waiver' };

const STATUS_LABELS = {
    Acknowledged:        'Approved',
    Local_Board_Approved:'Approved',
    State_Board_Approved:'Approved',
    Approved:            'Approved',
    Submitted:           'Submitted',
    Proposed:            'Proposed',
    Returned:            'Returned',
    Cancelled:           'Cancelled'
};

const SCOPE_LABELS = {
    District_Wide:     'District-Wide',
    Multiple_Schools:  'Multiple Schools',
    Single_School:     'Single School'
};

export default class ClosureKanbanCard extends NavigationMixin(LightningElement) {
    @api card;

    get cardClass() {
        let cls = 'kanban-card type-' + this.card.type;
        if (this.card.isUrgent) cls += ' urgent';
        return cls;
    }

    get typeBadgeClass() {
        return 'type-badge badge-' + this.card.type;
    }

    get tierClass() {
        if (!this.card.tier) return 'tier-pill';
        return 'tier-pill tier-' + this.card.tier.replace(' ', '').toLowerCase();
    }

    get typeLabel() {
        return TYPE_LABELS[this.card.type] || this.card.type;
    }

    get scopeLabel() {
        return SCOPE_LABELS[this.card.scope] || this.card.scope;
    }

    get statusLabel() {
        return STATUS_LABELS[this.card.status] || this.card.status;
    }

    get isTodo() {
        return this.card.column === 'todo';
    }

    get isDone() {
        return this.card.column === 'done';
    }

    handleNavigate() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.card.recordId, actionName: 'view' }
        });
    }

    handleApprove() {
        this.dispatchEvent(new CustomEvent('approve', {
            detail: { workItemId: this.card.workItemId, recordId: this.card.recordId }
        }));
    }

    handleReturn() {
        this.dispatchEvent(new CustomEvent('return', {
            detail: { workItemId: this.card.workItemId, recordId: this.card.recordId }
        }));
    }
}
