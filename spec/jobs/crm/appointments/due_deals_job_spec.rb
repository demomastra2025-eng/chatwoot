require 'rails_helper'

RSpec.describe Crm::Appointments::DueDealsJob do
  it 'leases only a bounded set of due open deals and does not enqueue them twice' do
    stub_const('Crm::Appointments::DueDealsJob::BATCH_SIZE', 2)
    due = create_list(:crm_deal, 3, appointment_automation_next_check_at: 1.minute.ago)
    future = create(:crm_deal, appointment_automation_next_check_at: 1.hour.from_now)
    closed = create(:crm_deal, appointment_automation_next_check_at: 1.minute.ago, closed_at: Time.current)
    archived = create(:crm_deal, appointment_automation_next_check_at: 1.minute.ago, archived_at: Time.current)
    allow(Crm::Appointments::EvaluateDealJob).to receive(:perform_later)

    described_class.perform_now
    expect(Crm::Appointments::EvaluateDealJob).to have_received(:perform_later).exactly(2).times
    expect(due.count { |deal| deal.reload.appointment_automation_next_check_at > Time.current }).to eq(2)
    described_class.perform_now
    expect(Crm::Appointments::EvaluateDealJob).to have_received(:perform_later).exactly(3).times
    described_class.perform_now
    expect(Crm::Appointments::EvaluateDealJob).to have_received(:perform_later).exactly(3).times
    [future, closed, archived].each do |deal|
      expect(Crm::Appointments::EvaluateDealJob).not_to have_received(:perform_later).with(deal.account_id, deal.id)
    end
  end

  it 'ignores an account-mismatched deal when processing an evaluation job' do
    deal = create(:crm_deal)
    other_account = create(:account)
    expect(Crm::Appointments::AutomationService).not_to receive(:new)

    Crm::Appointments::EvaluateDealJob.perform_now(other_account.id, deal.id)
  end

  it 'refreshes only enabled pipelines when the workspace clock changes' do
    account = create(:account, reporting_timezone: 'UTC')
    account.enable_features!('crm_deals')
    enabled = create(:crm_pipeline, account: account, appointment_automation: { enabled: true })
    create(:crm_pipeline, account: account)
    allow(Crm::Appointments::RefreshPipelineJob).to receive(:perform_later)
    account.update!(reporting_timezone: 'Asia/Almaty')

    expect(Crm::Appointments::RefreshPipelineJob).to have_received(:perform_later).with(account.id, enabled.id).once
    expect(Crm::Appointments::RefreshPipelineJob).to have_received(:perform_later).once
  end
end
