# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain follow-up WhatsApp retry dispatch', type: :job do
  let(:api_version) { 'v25.0' }

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return(api_version)
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', '').and_return('')
  end

  def materialized_follow_up
    channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false
    )
    account = channel.account
    account.enable_features!('captain_integration')
    inbox = channel.inbox
    contact = create(:contact, account: account, phone_number: '+123456789')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => '',
          'steps' => [
            { 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 },
            { 'mode' => 'static', 'message' => 'One more thought.', 'delay_seconds' => 120 }
          ]
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Can you help?'
    )
    anchor = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
    fence = {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: fence
    )
    claim = reminder.mark_processing!
    message = Reminders::MessageMaterializer.new(
      reminder: reminder,
      additional_attributes: {
        'captain_follow_up' => {
          'assistant_id' => assistant.id,
          'anchor_message_id' => anchor.id,
          'step_index' => 0,
          'control_fence' => fence
        }
      }
    ).perform(
      conversation: conversation,
      sender: assistant,
      content: 'Checking in.',
      delivery_policy: nil
    )
    reminder.update!(status: :completed, completed_at: Time.current)
    message.update!(source_id: nil)

    [channel, account, conversation, assistant, reminder, claim, message]
  end

  def transient_meta_error_response
    {
      status: 500,
      body: {
        error: {
          message: 'An unknown error has occurred',
          type: 'OAuthException',
          code: 1,
          fbtrace_id: 'trace-1'
        }
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    }
  end

  it 'blocks the real queued Meta transient retry after the assistant feature is disabled' do
    _channel, account, _conversation, _assistant, reminder, claim, message = materialized_follow_up
    request = stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
              .to_return(transient_meta_error_response)

    Reminders::DeliverMaterializedMessageJob.perform_now(reminder.id, message.id, claim)

    expect(request).to have_been_made.once
    expect(message.reload).to be_sent
    expect(reminder.reload.delivery_stage).to eq('retry_scheduled')
    expect(SendReplyJob).to have_been_enqueued.with(message.id).on_queue('outbound_messages')

    account.disable_features!('captain_integration')
    SendReplyJob.perform_now(message.id)

    expect(request).to have_been_made.once
    expect(message.reload).to be_failed
    expect(reminder.reload).to be_cancelled
    expect(reminder).to be_captain_follow_up_delivery_suppressed
  end

  it 'commits a successful direct Meta retry and advances the chain once' do
    _channel, _account, conversation, assistant, reminder, claim, message = materialized_follow_up
    request = stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
              .to_return(
                transient_meta_error_response,
                {
                  status: 200,
                  body: { messages: [{ id: 'wamid.follow-up-retry' }] }.to_json,
                  headers: { 'Content-Type' => 'application/json' }
                }
              )

    Reminders::DeliverMaterializedMessageJob.perform_now(reminder.id, message.id, claim)
    expect(reminder.reload.delivery_stage).to eq('retry_scheduled')

    SendReplyJob.perform_now(message.id)

    expect(request).to have_been_made.twice
    expect(message.reload.source_id).to eq('wamid.follow-up-retry')
    expect(reminder.reload.delivery_stage).to eq('provider_accepted')
    expect(reminder).to be_delivery_dispatched_for(message.id)
    expect(
      conversation.account.reminders.captain_follow_up.find_by!(
        idempotency_key: "captain_follow_up:#{assistant.id}:#{message.id}:1"
      )
    ).to be_pending

    SendReplyJob.perform_now(message.id)

    expect(request).to have_been_made.twice
    expect(conversation.account.reminders.captain_follow_up.count).to eq(2)
  end

  it 'retries next-step scheduling after provider acceptance without sending to Meta again' do
    _channel, _account, conversation, assistant, reminder, claim, message = materialized_follow_up
    request = stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
              .to_return(
                transient_meta_error_response,
                {
                  status: 200,
                  body: { messages: [{ id: 'wamid.follow-up-retry' }] }.to_json,
                  headers: { 'Content-Type' => 'application/json' }
                }
              )

    Reminders::DeliverMaterializedMessageJob.perform_now(reminder.id, message.id, claim)
    scheduling_attempts = 0
    allow(Captain::Conversation::FollowUpJob).to receive(:schedule_after_delivery!).and_wrap_original do |original, *args, **kwargs|
      scheduling_attempts += 1
      raise Reminders::RetryableExecutionError, 'temporary scheduler failure' if scheduling_attempts == 1

      original.call(*args, **kwargs)
    end

    expect do
      SendReplyJob.perform_now(message.id)
    end.to have_enqueued_job(SendReplyJob).with(message.id)
    expect(reminder.reload.delivery_stage).to eq('provider_accepted')

    SendReplyJob.perform_now(message.id)

    expect(request).to have_been_made.twice
    expect(scheduling_attempts).to eq(2)
    expect(
      conversation.account.reminders.captain_follow_up.find_by!(
        idempotency_key: "captain_follow_up:#{assistant.id}:#{message.id}:1"
      )
    ).to be_pending
  end
end
