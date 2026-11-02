require 'rails_helper'

RSpec.describe Message do
  include_context 'with active AI metering'
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

  it 'retains the provider ack and recovers usage without another external send after a counter fault' do
    message = reply
    sends = 0
    allow(inbox.channel).to receive(:send_message_on_telegram) do
      sends += 1
      "synthetic-provider-ack-#{sends}"
    end
    metering = Accounts::MonthlyAiUsageService.new(account)
    allow(Accounts::MonthlyAiUsageService).to receive(:new).with(account).and_return(metering)
    allow(metering).to receive(:increment_monthly_bucket!).and_raise(ActiveRecord::StatementInvalid, 'injected failure')
    Telegram::SendOnTelegramService.new(message: message).perform
    expect(message.reload).to have_attributes(source_id: 'synthetic-provider-ack-1', ai_usage_pending: true)
    expect(Accounts::AiUsageEvent.count).to eq(0)
    Telegram::SendOnTelegramService.new(message: message).perform
    expect(sends).to eq(1)

    allow(metering).to receive(:increment_monthly_bucket!).and_call_original
    travel 2.minutes do
      2.times { Accounts::DrainAiUsageJob.perform_now }
    end
    expect(usage.ai_dialogs_consumed).to eq(1)
    expect(Accounts::AiUsageEvent.count).to eq(1)
    expect(message.reload.ai_usage_pending).to be(false)
  end

  it 'retains earlier paid windows when feedback arrives after a newer window, including across months' do
    first = Time.utc(2026, 10, 30, 8)
    earlier = nil
    travel_to(first) { earlier = reply(source_id: 'human-original-ack', additional_attributes: {}) }
    travel_to(first + 1.minute) { reply(source_id: 'first-auto-ack') }
    travel_to(first + 3.days) do
      reply(source_id: 'second-auto-ack')
      before = usage.ai_dialogs_consumed(at: first) + usage.ai_dialogs_consumed
      earlier.update!(additional_attributes: { 'captain_ai_suggestion' => {} })
      after_feedback = usage.ai_dialogs_consumed(at: first) + usage.ai_dialogs_consumed
      reply(source_id: 'second-window-next-ack')
      after_current = usage.ai_dialogs_consumed(at: first) + usage.ai_dialogs_consumed
      expect([before, after_feedback, after_current]).to eq([2, 2, 2])
      expect([usage.ai_dialogs_consumed(at: first), usage.ai_dialogs_consumed]).to eq([1, 1])
      state = Accounts::AiDialogState.find_by!(contact_id: conversation.contact_id).state
      expect(state['windows'].size).to eq(2)
      expect(Time.iso8601(state['started_at'])).to eq(first + 3.days)
    end
  end

  it 'recovers from a process interruption after ack commit before the immediate reconcile runs' do
    allow(Accounts::AiUsageOutbox).to receive(:deliver).and_return(false)
    message = reply(source_id: 'durable-ack')
    expect(message.reload.ai_usage_pending).to be(true)
    allow(Accounts::AiUsageOutbox).to receive(:deliver).and_call_original
    Accounts::DrainAiUsageJob.perform_now
    expect(usage.ai_dialogs_consumed).to eq(1)
    expect(message.reload.ai_usage_pending).to be(false)
  end
end
