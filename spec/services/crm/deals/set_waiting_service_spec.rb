require 'rails_helper'

RSpec.describe Crm::Deals::SetWaitingService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:deal) { create(:crm_deal, account: account, owner: actor) }

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'provisions task catalogs before locking the deal and creating a wake-up task' do
    account.crm_task_outcomes.find_by!(code: 'busy').destroy!
    lock_order = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      lock_order << :catalog if sql.include?('pg_advisory_xact_lock')
      lock_order << :deal if sql.match?(/FROM "crm_deals".*FOR UPDATE/)
      lock_order << :task if sql.start_with?('INSERT INTO "crm_tasks"')
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.new(
        account: account,
        deal: deal,
        actor: actor,
        params: {
          waiting_until: 1.day.from_now,
          waiting_reason: 'Awaiting response',
          create_wake_up_task: true,
          wake_up_task_title: 'Follow up',
          lock_version: deal.lock_version
        }
      ).perform
    end

    expect(lock_order).to eq(%i[catalog deal task])
    expect(deal.tasks.find_by!(title: 'Follow up')).to have_attributes(context_kind: 'sales')
  end
end
