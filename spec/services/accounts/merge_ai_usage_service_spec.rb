require 'rails_helper'

RSpec.describe Accounts::MergeAiUsageService do
  include_context 'with active AI metering'
  let(:account) { create(:account) }
  let(:target) { create(:contact, account: account) }
  let(:source) { create(:contact, account: account) }
  let(:inbox) { create(:channel_telegram, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, contact: source, inbox: inbox) }

  def reply(chat = conversation, ack: 'before-merge-ack')
    create(:message, account: account, conversation: chat, message_type: :outgoing, source_id: ack,
                     additional_attributes: { 'captain_ai_reply' => {} })
  end

  def usage(at: Time.current)
    Accounts::MonthlyAiUsageService.new(account.reload).ai_dialogs_consumed(at: at)
  end

  def merge
    ContactMergeAction.new(account: account, base_contact: target, mergee_contact: source).perform
  end

  it 'preserves the paid window and source identity through the real manual merge' do
    message = reply
    expect(usage).to eq(1)
    merge
    expect(Accounts::AiUsageEvent.find_by!(event_key: "message:#{message.id}").contact_id).to eq(target.id)
    expect(Accounts::AiDialogState.where(account_id: account.id).count).to eq(1)
    reply(conversation.reload, ack: 'after-merge-ack')
    expect(usage).to eq(1)
  end

  it 'uses the same billing transfer when channel sync deletes a duplicate' do
    message = reply
    expect(Contacts::ChannelSyncMergeService.new(source_contact: source, target_contact: target).perform).to be(true)
    expect(Contact.exists?(source.id)).to be(false)
    expect(Accounts::AiUsageEvent.find_by!(event_key: "message:#{message.id}").contact_id).to eq(target.id)
    reply(conversation.reload, ack: 'after-channel-merge-ack')
    expect(usage).to eq(1)
  end

  it 'combines two already counted sides with chronological month deltas and preserves later deduplication' do
    october = Time.utc(2026, 10, 31, 18, 59)
    november = Time.utc(2026, 10, 31, 19, 1)
    other = create(:conversation, account: account, contact: target, inbox: create(:inbox, account: account))
    old = nil
    travel_to(october) { old = reply(other, ack: 'october-ack') }
    travel_to(november) { reply }
    expect([usage(at: october), usage(at: november)]).to eq([1, 1])
    merge
    expect([usage(at: october), usage(at: november)]).to eq([1, 0])
    old.reload.update!(status: :read)
    travel_to(november + 1.hour) { reply(conversation.reload, ack: 'current-merged-ack') }
    expect([usage(at: october), usage(at: november)]).to eq([1, 0])
    expect(Accounts::AiUsageEvent.where(account_id: account.id).distinct.pluck(:contact_id)).to eq([target.id])
  end

  it 'keeps both legacy reply blocks even when their timestamps and counts coincide' do
    now = Time.current
    target_chat = create(:conversation, account: account, contact: target, inbox: create(:inbox, account: account))
    [conversation, target_chat].each do |chat|
      chat.update!(additional_attributes: { 'captain_ai_dialog_window' => { 'started_at' => now.iso8601, 'replies_count' => 10 } })
    end
    account.update!(custom_attributes: { 'captain_ai_dialogs_monthly' => { Accounts::MonthlyAiUsageService.new(account).period_key(now) => 2 } })
    merge
    expect(usage).to eq(2)
    reply(conversation.reload, ack: 'twenty-first-after-legacy-merge')
    expect(usage).to eq(3)
  end

  it 'moves generated ownership when same-inbox conversations are consolidated during merge' do
    source_chat = conversation
    target_chat = create(:conversation, account: account, contact: target, inbox: inbox)
    target_chat.update_columns(last_activity_at: 1.hour.from_now) # rubocop:disable Rails/SkipsModelValidations
    agent = create(:user, account: account)
    identity = Captain::ReplySuggestion::Identity.create!(request_id: SecureRandom.uuid, account: account, user: agent,
                                                          conversation: source_chat, generated_at: Time.current)
    merge
    expect(Conversation.exists?(source_chat.id)).to be(false)
    expect(identity.reload.conversation_id).to eq(target_chat.id)
  end

  it 'preserves separate billing histories when clinical patient references move without merging communication contacts' do
    source_chat = conversation
    source_chat.update!(additional_attributes: { 'captain_ai_dialog_window' => { 'started_at' => Time.current.iso8601, 'replies_count' => 10 } })
    target_chat = create(:conversation, account: account, contact: target)
    period = Accounts::MonthlyAiUsageService.new(account).period_key
    account.update!(custom_attributes: { 'captain_ai_dialogs_monthly' => { period => 1 } })
    reply(target_chat, ack: 'target-before-clinical-transfer')
    Contact.transaction do
      Integrations::Medelement::PatientContactTransferService.new(
        account: account, source_contact: source, destination_contact: target
      ).perform
    end
    expect(source_chat.reload.contact_id).to eq(source.id)
    expect(target_chat.reload.contact_id).to eq(target.id)
    expect(Accounts::AiUsageEvent.where(account_id: account.id).pluck(:contact_id)).to eq([target.id])
    reply(source_chat, ack: 'source-after-clinical-transfer')
    reply(target_chat, ack: 'target-after-clinical-transfer')
    expect(usage).to eq(2)
    expect(Accounts::AiDialogState.where(account_id: account.id).count).to eq(2)
  end

  it 'rejects cross-account merge without moving the billed event' do
    event = reply
    foreign = create(:contact)
    expect do
      ContactMergeAction.new(account: account, base_contact: foreign, mergee_contact: source).perform
    end.to raise_error(StandardError, /does not belong/)
    expect(Accounts::AiUsageEvent.find_by!(event_key: "message:#{event.id}").contact_id).to eq(source.id)
    expect(usage).to eq(1)
  end
end
