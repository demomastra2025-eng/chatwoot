require 'rails_helper'

RSpec.describe Crm::Deals::NextActionService do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:deal) { create(:crm_deal, account: account) }
  let(:open_status) { create(:crm_task_status, account: account, category: 'open') }

  around do |example|
    travel_to(Time.zone.parse('2026-09-04 10:00:00')) { example.run }
  end

  it 'returns expired waiting before an overdue task' do
    deal.update!(
      waiting_until: 1.hour.ago,
      waiting_reason: 'Waiting for customer',
      waiting_started_at: 2.days.ago
    )
    create(:crm_task, account: account, deal: deal, status: open_status, due_at: 1.day.ago)

    result = described_class.new(deal: deal).perform

    expect(result).to include(
      kind: 'waiting_expired',
      waiting_reason: 'Waiting for customer'
    )
  end

  it 'selects the earliest actionable task using overdue, today and future buckets' do
    future_task = create(:crm_task, account: account, deal: deal, status: open_status, due_at: 1.day.from_now)
    today_task = create(:crm_task, account: account, deal: deal, status: open_status, due_on: Date.current, all_day: true)
    overdue_task = create(:crm_task, account: account, deal: deal, status: open_status, due_at: 1.hour.ago)

    result = described_class.new(deal: deal).perform

    expect(result).to include(kind: 'task', state: 'overdue')
    expect(result.dig(:task, :id)).to eq(overdue_task.id)
    expect(result.dig(:task, :id)).not_to be_in([today_task.id, future_task.id])
  end

  it 'ignores completed tasks and returns no action' do
    done_status = create(:crm_task_status, account: account, category: 'done')
    create(:crm_task, account: account, deal: deal, status: done_status, due_at: 1.hour.from_now)

    expect(described_class.new(deal: deal).perform).to eq(kind: 'none', reason: 'no_open_task')
  end
end
