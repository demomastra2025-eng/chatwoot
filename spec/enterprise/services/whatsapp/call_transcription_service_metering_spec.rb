require 'rails_helper'

RSpec.describe Whatsapp::CallTranscriptionService do
  let(:account) { create(:account, call_transcriptions: true) }
  let(:call) { create(:call, account: account, status: 'completed', duration_seconds: 31) }
  let(:service) { described_class.new(call) }
  let(:metering) { Accounts::MonthlyAiUsageService.new(account) }

  before do
    allow(Llm::Config).to receive(:api_key).and_return('test-key')
    allow(Accounts::MonthlyAiUsageService).to receive(:new).with(account).and_return(metering)
  end

  def store(text = 'Synthetic transcript')
    service.send(:update_call_and_message, text)
  end

  it 'rolls back transcript and usage on a fault after the usage write, allowing the job to retry' do
    allow(metering).to receive(:record_call_analysis!).and_wrap_original do |original, **args|
      original.call(**args)
      raise ActiveRecord::StatementInvalid, 'injected after usage write'
    end
    expect { store }.to raise_error(ActiveRecord::StatementInvalid)
    expect(call.reload.transcript).to be_blank
    expect(Accounts::AiUsageEvent.count).to eq(0)
    expect(account.reload.custom_attributes['call_analysis_seconds_monthly']).to be_nil

    allow(metering).to receive(:record_call_analysis!).and_call_original
    store
    store('Another retry')
    expect(call.reload.transcript).to eq('Synthetic transcript')
    expect(metering.class.new(account.reload).call_analysis_seconds_consumed).to eq(31)
    expect(Accounts::AiUsageEvent.count).to eq(1)
  end

  it 'does not charge a historical transcript that was already present before migration' do
    call.update!(transcript: 'Historical transcript')
    store
    expect(call.reload.transcript).to eq('Historical transcript')
    expect(Accounts::AiUsageEvent.count).to eq(0)
  end

  it 'does not charge unanswered or short calls' do
    call.update!(duration_seconds: 4)
    store
    other = create(:call, account: account, status: 'no_answer', duration_seconds: 31)
    described_class.new(other).send(:update_call_and_message, 'No answer')
    expect(Accounts::AiUsageEvent.count).to eq(0)
  end
end
