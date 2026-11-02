require 'rails_helper'

RSpec.describe Accounts::DrainAiUsageJob do
  include_context 'with active AI metering'

  it 'drains a bounded due batch in retry order and leaves deferred failures for a later cron' do
    message = create(:message, message_type: :outgoing, source_id: 'ack')
    message.update_columns(ai_usage_pending: true, ai_usage_retry_at: 2.minutes.from_now) # rubocop:disable Rails/SkipsModelValidations
    expect(Accounts::AiUsageOutbox).not_to receive(:deliver)
    described_class.perform_now
    expect(message.reload.ai_usage_pending).to be(true)
  end

  it 'limits one drain invocation to its configured batch and defers failed rows' do
    stub_const('Accounts::DrainAiUsageJob::BATCH_SIZE', 1)
    allow(Accounts::AiUsageOutbox).to receive(:deliver).and_return(false)
    first = create(:message, message_type: :outgoing, source_id: 'first-ack')
    second = create(:message, message_type: :outgoing, source_id: 'second-ack')
    allow(Accounts::AiUsageOutbox).to receive(:deliver).and_call_original
    metering = Accounts::MonthlyAiUsageService.new(first.account)
    allow(Accounts::MonthlyAiUsageService).to receive(:new).and_call_original
    allow(Accounts::MonthlyAiUsageService).to receive(:new).with(first.account).and_return(metering)
    allow(metering).to receive(:record_sent_message!).and_raise(ActiveRecord::StatementInvalid, 'injected failure')
    described_class.perform_now
    expect(first.reload.ai_usage_retry_at).to be > Time.current
    expect(second.reload.ai_usage_pending).to be(true)
    described_class.perform_now
    expect(second.reload.ai_usage_pending).to be(false)
  end

  it 'registers recovery on the staggered second of each minute' do
    schedule = YAML.safe_load(Rails.root.join('config/schedule.yml').read)
    expect(schedule['drain_ai_usage_job']).to include('cron' => '17 * * * * *', 'active_job' => true)
    expect(described_class::BATCH_SIZE).to eq(200)
  end
end
