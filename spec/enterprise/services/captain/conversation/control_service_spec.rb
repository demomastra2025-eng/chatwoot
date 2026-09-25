# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Conversation::ControlService do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_widget, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before { account.enable_features!('scheduling') }

  def provider_command(status:, conversation_id: conversation.id, origin: true)
    origin_state = {
      'captain_action_origin' => {
        'assistant_id' => 123,
        'conversation_id' => conversation_id,
        'control_generation' => conversation.current_captain_control_generation
      }
    }
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      operation: 'create_patient',
      status: status,
      idempotency_key: SecureRandom.uuid,
      execution_state: origin ? origin_state : {}
    )
  end

  it 'cancels queued and awaiting Captain actions immediately at human takeover without touching unrelated actions' do
    queued = provider_command(status: 'v2_queued')
    awaiting = provider_command(status: 'awaiting_confirmation')
    patient_action = provider_command(status: 'v2_awaiting_patient_selection')
    non_captain = provider_command(status: 'v2_queued', origin: false)
    other_conversation = create(:conversation, account: account, inbox: inbox)
    unrelated = provider_command(status: 'v2_queued', conversation_id: other_conversation.id)
    processing = provider_command(status: 'v2_processing')

    expect(conversation.activate_captain_human_control!(source: 'agent_reply')).to be(true)

    [queued, awaiting, patient_action].each do |command|
      expect(command.reload).to have_attributes(status: 'cancelled', last_error_code: 'captain_control_stale')
      expect(command.executed_at).to be_present
    end
    expect(non_captain.reload).to be_v2_queued
    expect(unrelated.reload).to be_v2_queued
    expect(processing.reload).to be_v2_processing
  end

  it 'cancels actions from another channel projection of the same communication thread' do
    linked = create(:conversation, account: account, inbox: inbox, contact: conversation.contact)
    thread = create(:communication_thread, account: account, contact: conversation.contact)
    create(:communication_thread_conversation, account: account, communication_thread: thread, conversation: conversation, primary: true)
    create(:communication_thread_conversation, account: account, communication_thread: thread, conversation: linked)
    expect(conversation.reload.communication_thread.conversations.pluck(:id)).to include(linked.id)
    pending_action = provider_command(status: 'queued', conversation_id: linked.id)

    conversation.activate_captain_human_control!(source: 'agent_reply')

    expect(pending_action.reload).to be_cancelled
  end

  it 'sees a human reply on another contact channel before thread linking, even without Captain on that inbox' do
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    trigger = create(:message, conversation: conversation, message_type: :incoming)
    other_inbox = create(:channel_widget, account: account).inbox
    contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_inbox)
    other_conversation = create(:conversation, account: account, inbox: other_inbox, contact: conversation.contact,
                                               contact_inbox: contact_inbox)
    create(:message, conversation: other_conversation, message_type: :outgoing, sender: create(:user, account: account))

    expect(other_conversation.reload.communication_thread).to be_nil
    expect(described_class.human_response_after?(conversation, trigger.id)).to be(true)
  end

  it 'cancels pending Captain actions on a Captain-initiated handoff as well' do
    pending_action = provider_command(status: 'v2_queued')

    expect(conversation.bot_handoff!(source: 'captain')).to eq(:applied)

    expect(pending_action.reload).to be_cancelled
  end
end
