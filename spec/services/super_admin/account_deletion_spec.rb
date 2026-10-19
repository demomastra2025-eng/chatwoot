require 'rails_helper'

RSpec.describe SuperAdmin::AccountDeletion do
  subject(:deletion) { described_class.new(account: account, actor: super_admin) }

  let!(:account) { create(:account, name: 'Аккаунт Алатау', custom_attributes: { 'plan' => 'base' }) }
  let!(:super_admin) { create(:super_admin) }

  describe '#schedule' do
    it 'marks the account for deletion after the grace period and keeps its other attributes' do
      freeze_time do
        expect(deletion.schedule).to eq(:scheduled)

        expect(account.reload.custom_attributes).to include(
          'plan' => 'base', 'marked_for_deletion_at' => 7.days.from_now.iso8601, 'marked_for_deletion_reason' => 'manual_deletion'
        )
        expect(deletion.deletion_at).to eq(7.days.from_now.change(usec: 0))
      end
    end

    it 'does not enqueue any deletion and sends nobody an e-mail' do
      expect(DeleteObjectJob).not_to receive(:perform_later)

      expect { deletion.schedule }.not_to have_enqueued_mail
    end

    it 'does not move the date of a deletion that is scheduled already' do
      deletion.schedule
      first = account.reload.custom_attributes['marked_for_deletion_at']

      travel_to(1.day.from_now) do
        expect(described_class.new(account: account.reload, actor: super_admin).schedule).to eq(:already_scheduled)
      end

      expect(account.reload.custom_attributes['marked_for_deletion_at']).to eq(first)
      expect(Audited::Audit.where(action: 'schedule_deletion').count).to eq(1)
    end

    it 'shows the account as being deleted' do
      deletion.schedule

      expect(SuperAdmin::AccountPlanState.new(account.reload).status).to eq(:deleting)
    end
  end

  describe '#cancel' do
    it 'removes the mark and records it' do
      deletion.schedule

      expect(deletion.cancel).to eq(:cancelled)

      expect(account.reload.custom_attributes).to eq('plan' => 'base')
      expect(deletion).not_to be_scheduled
      expect(Audited::Audit.where(auditable: account, action: 'cancel_deletion').sole.user_id).to eq(super_admin.id)
    end

    it 'does nothing for an account that is not scheduled' do
      expect(deletion.cancel).to eq(:not_scheduled)

      expect(Audited::Audit.where(action: 'cancel_deletion')).to be_empty
    end
  end

  describe '#deletion_at' do
    it 'is nil without a mark and for a mark that is not a date' do
      expect(deletion.deletion_at).to be_nil

      account.update!(custom_attributes: { 'marked_for_deletion_at' => 'not a date' })
      expect(described_class.new(account: account.reload).deletion_at).to be_nil
    end
  end
end
