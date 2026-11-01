require 'rails_helper'

RSpec.describe Message do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_telegram, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  def usage
    Accounts::MonthlyAiUsageService.new(account.reload)
  end

  def reply(**attributes)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                     additional_attributes: { 'captain_ai_reply' => {} }, **attributes)
  end

  it 'counts an autonomous AI reply on provider ack once, while unsent, failed and private messages stay free' do
    unsent = reply
    reply(status: :failed, source_id: 'failed-ack')
    reply(private: true, source_id: 'note-ack')
    expect(usage.ai_dialogs_consumed).to eq(0)
    unsent.update!(source_id: 'provider-ack')
    unsent.update!(status: :read)
    expect(usage.ai_dialogs_consumed).to eq(1)
    expect(Accounts::AiUsageEvent.count).to eq(1)
  end

  it 'uses persisted suggestion provenance when the provider saves an object loaded before feedback' do
    message = reply(additional_attributes: {})
    stale_provider_copy = described_class.find(message.id)
    message.update!(additional_attributes: { 'captain_ai_suggestion' => { 'request_id' => 'synthetic-request' } })
    stale_provider_copy.update!(source_id: 'provider-ack')
    expect(usage.ai_dialogs_consumed).to eq(1)
    expect(message.reload.additional_attributes).to have_key('captain_ai_suggestion')
  end

  it 'assigns late suggestion feedback to the original acknowledged month in Almaty' do
    message = nil
    travel_to Time.utc(2026, 10, 31, 18, 59) do
      message = reply(additional_attributes: {}, source_id: 'october-ack')
    end
    travel_to Time.utc(2026, 10, 31, 19, 1) do
      message.update!(additional_attributes: { 'captain_ai_suggestion' => {} })
      expect(usage.ai_dialogs_consumed(at: Time.utc(2026, 10, 31, 18, 59))).to eq(1)
      expect(usage.ai_dialogs_consumed).to eq(0)
    end
  end

  it 'absorbs earlier acknowledged feedback into a newer window and moves its month once' do
    earlier = nil
    travel_to Time.utc(2026, 10, 31, 18, 59) do
      earlier = reply(additional_attributes: {}, source_id: 'earlier-ack')
    end
    travel_to Time.utc(2026, 10, 31, 19, 1) do
      reply(source_id: 'newer-ai-ack')
      earlier.update!(additional_attributes: { 'captain_ai_suggestion' => {} })
      expect(usage.ai_dialogs_consumed(at: Time.utc(2026, 10, 31, 18, 59))).to eq(1)
      expect(usage.ai_dialogs_consumed).to eq(0)
      expect(Accounts::AiDialogState.find_by!(contact_id: conversation.contact_id).state['replies_count']).to eq(2)
    end
  end

  it 'rolls back the message acknowledgement along with the window and counter when accounting fails' do
    message = reply
    metering = Accounts::MonthlyAiUsageService.new(account)
    allow(Accounts::MonthlyAiUsageService).to receive(:new).with(account).and_return(metering)
    allow(metering).to receive(:increment_monthly_bucket!).and_raise(ActiveRecord::StatementInvalid, 'injected failure')
    expect { message.update!(source_id: 'provider-ack') }.to raise_error(ActiveRecord::StatementInvalid)
    expect(message.reload.source_id).to be_nil
    expect(message.ai_usage_sent_at).to be_nil
    expect(Accounts::AiUsageEvent.count).to eq(0)
    allow(metering).to receive(:increment_monthly_bucket!).and_call_original
    message.update!(source_id: 'provider-ack')
    expect(usage.ai_dialogs_consumed).to eq(1)
  end
end
