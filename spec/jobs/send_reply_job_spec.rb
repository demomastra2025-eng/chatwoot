require 'rails_helper'

RSpec.describe SendReplyJob do
  subject(:job) { described_class.perform_later(message) }

  let(:message) { create(:message) }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(message)
      .on_queue('outbound_messages')
  end

  context 'when the job is triggered on a new message' do
    let(:process_service) { double }

    before do
      allow(process_service).to receive(:perform)
    end

    it 'calls Facebook::SendOnFacebookService when its facebook message' do
      stub_request(:post, /graph.facebook.com/)
      facebook_channel = create(:channel_facebook_page)
      facebook_inbox = create(:inbox, channel: facebook_channel)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: facebook_inbox))
      allow(Facebook::SendOnFacebookService).to receive(:new).with(message: message).and_return(process_service)
      expect(Facebook::SendOnFacebookService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Twitter::SendOnTwitterService when its twitter message' do
      twitter_channel = create(:channel_twitter_profile)
      twitter_inbox = create(:inbox, channel: twitter_channel)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: twitter_inbox))
      allow(Twitter::SendOnTwitterService).to receive(:new).with(message: message).and_return(process_service)
      expect(Twitter::SendOnTwitterService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Twilio::SendOnTwilioService when its twilio message' do
      twilio_channel = create(:channel_twilio_sms)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: twilio_channel.inbox))
      allow(Twilio::SendOnTwilioService).to receive(:new).with(message: message).and_return(process_service)
      expect(Twilio::SendOnTwilioService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Telegram::SendOnTelegramService when its telegram message' do
      telegram_channel = create(:channel_telegram)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: telegram_channel.inbox))
      allow(Telegram::SendOnTelegramService).to receive(:new).with(message: message).and_return(process_service)
      expect(Telegram::SendOnTelegramService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Line:SendOnLineService when its line message' do
      line_channel = create(:channel_line)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: line_channel.inbox))
      allow(Line::SendOnLineService).to receive(:new).with(message: message).and_return(process_service)
      expect(Line::SendOnLineService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Whatsapp:SendOnWhatsappService when its whatsapp message' do
      stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
      whatsapp_channel = create(:channel_whatsapp, sync_templates: false)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: whatsapp_channel.inbox))
      allow(Whatsapp::SendOnWhatsappService).to receive(:new).with(message: message).and_return(process_service)
      expect(Whatsapp::SendOnWhatsappService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Sms::SendOnSmsService when its sms message' do
      sms_channel = create(:channel_sms)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: sms_channel.inbox))
      allow(Sms::SendOnSmsService).to receive(:new).with(message: message).and_return(process_service)
      expect(Sms::SendOnSmsService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Instagram::Direct::SendOnInstagramService when its instagram message' do
      instagram_channel = create(:channel_instagram)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: instagram_channel.inbox))
      allow(Instagram::SendOnInstagramService).to receive(:new).with(message: message).and_return(process_service)
      expect(Instagram::SendOnInstagramService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Instagram::Messenger::SendOnInstagramService when its an instagram_direct_message from facebook channel' do
      stub_request(:post, /graph.facebook.com/)
      facebook_channel = create(:channel_facebook_page)
      facebook_inbox = create(:inbox, channel: facebook_channel)
      conversation = create(:conversation,
                            inbox: facebook_inbox,
                            additional_attributes: { 'type' => 'instagram_direct_message' })
      message = create(:message, message_type: 'outgoing', conversation: conversation)

      allow(Instagram::Messenger::SendOnInstagramService).to receive(:new).with(message: message).and_return(process_service)
      expect(Instagram::Messenger::SendOnInstagramService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Email::SendOnEmailService when its email message' do
      email_channel = create(:channel_email)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: email_channel.inbox))
      allow(Email::SendOnEmailService).to receive(:new).with(message: message).and_return(process_service)
      expect(Email::SendOnEmailService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Messages::SendEmailNotificationService when its webwidget message' do
      webwidget_channel = create(:channel_widget)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: webwidget_channel.inbox))
      allow(Messages::SendEmailNotificationService).to receive(:new).with(message: message).and_return(process_service)
      expect(Messages::SendEmailNotificationService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Messages::SendEmailNotificationService when its api channel message' do
      api_channel = create(:channel_api)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: api_channel.inbox))
      allow(Messages::SendEmailNotificationService).to receive(:new).with(message: message).and_return(process_service)
      expect(Messages::SendEmailNotificationService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::WhatsappWeb::SendOnWhatsappWebService when its whatsapp web message' do
      with_modified_env(
        'EVOLUTION_API_URL' => 'https://evolution.example.com',
        'EVOLUTION_API_KEY' => 'test-api-key',
        'FRONTEND_URL' => 'https://app.example.com'
      ) do
        whatsapp_web_channel = create(:channel_whatsapp_web)
        message = create(:message, message_type: 'outgoing',
                                   conversation: create(:conversation, account: whatsapp_web_channel.account, inbox: whatsapp_web_channel.inbox))

        allow(WhatsappWeb::SendOnWhatsappWebService).to receive(:new).with(message: message).and_return(process_service)
        expect(WhatsappWeb::SendOnWhatsappWebService).to receive(:new).with(message: message)
        expect(process_service).to receive(:perform)
        described_class.perform_now(message.id)
      end
    end

    it 'calls ::Tiktok::SendOnTiktokService when its tiktok message' do
      tiktok_channel = create(:channel_tiktok)
      message = create(:message, message_type: 'outgoing', conversation: create(:conversation, inbox: tiktok_channel.inbox))
      allow(Tiktok::SendOnTiktokService).to receive(:new).with(message: message).and_return(process_service)
      expect(Tiktok::SendOnTiktokService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'does not call channel services for incoming messages' do
      incoming_message = create(:message)
      allow(Messages::SendEmailNotificationService).to receive(:new)

      described_class.perform_now(incoming_message.id)

      expect(Messages::SendEmailNotificationService).not_to have_received(:new)
    end
  end

  describe 'Captain public message delivery fence' do
    let(:account) { create(:account) }
    let(:channel) { create(:channel_widget, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, status: :pending) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:process_service) { instance_double(Messages::SendEmailNotificationService, perform: true) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
      allow(Messages::SendEmailNotificationService).to receive(:new).and_return(process_service)
    end

    def captain_message(kind: 'reply', generation: nil, trigger_id: nil, follow_up: false)
      incoming = conversation.messages.incoming.last || create(:message, message_type: :incoming, conversation: conversation)
      attributes = {
        'captain_delivery_fence' => {
          'assistant_id' => assistant.id,
          'control_generation' => generation || conversation.current_captain_control_generation,
          'trigger_message_id' => trigger_id || incoming.id,
          'kind' => kind
        }
      }
      attributes['captain_follow_up'] = { 'anchor_message_id' => trigger_id } if follow_up
      create(:message, message_type: :outgoing, conversation: conversation, sender: assistant,
                       additional_attributes: attributes)
    end

    it 'isolates Captain jobs from old outbound consumers for both id and record enqueues' do
      message = captain_message
      expect(described_class.perform_later(message.id).queue_name).to eq('captain_outbound_messages_v2')
      expect(described_class.perform_later(message).queue_name).to eq('captain_outbound_messages_v2')
      expect(YAML.load_file(Rails.root.join('config/sidekiq_outbound_messages.yml'), permitted_classes: [Symbol])[:queues])
        .to include('captain_outbound_messages_v2', 'outbound_messages')
    end

    it 'cancels a queued Captain reply if a human replies before channel dispatch' do
      message = captain_message
      create(:message, message_type: :outgoing, conversation: conversation, sender: create(:user, account: account))

      described_class.perform_now(message.id)

      expect(process_service).not_to have_received(:perform)
      expect(message.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
      expect(message).to be_failed
    end

    it 'cancels a queued Captain reply when a newer customer message arrives before dispatch' do
      reply = captain_message
      create(:message, message_type: :incoming, conversation: conversation)

      described_class.perform_now(reply.id)

      expect(process_service).not_to have_received(:perform)
      expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
      expect(reply).to be_failed
    end

    it 'cancels a reply when a newer customer message arrives on another channel of the same thread' do
      reply = captain_message
      account.enable_features!('communication_threads')
      thread = Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
      other_channel = create(:channel_widget, account: account)
      other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
      other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                                 inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
      expect(other_conversation.reload.communication_thread).to eq(thread)
      create(:message, message_type: :incoming, conversation: other_conversation)

      described_class.perform_now(reply.id)

      expect(process_service).not_to have_received(:perform)
      expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'cancels a queued reply if the conversation no longer permits Captain responses' do
      reply = captain_message
      conversation.update!(status: :resolved)

      described_class.perform_now(reply.id)

      expect(process_service).not_to have_received(:perform)
      expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'keeps an outgoing-anchored follow-up until a customer replies after its anchor' do
      anchor = captain_message
      follow_up = captain_message(trigger_id: anchor.id, follow_up: true)

      described_class.perform_now(follow_up.id)
      expect(process_service).to have_received(:perform).once

      later_follow_up = captain_message(trigger_id: anchor.id, follow_up: true)
      create(:message, message_type: :incoming, conversation: conversation)
      described_class.perform_now(later_follow_up.id)

      expect(process_service).to have_received(:perform).once
      expect(later_follow_up.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'rejects an old queued generation even if AI was reactivated afterwards' do
      message = captain_message
      create(:message, message_type: :outgoing, conversation: conversation, sender: create(:user, account: account))
      conversation.prepare_captain_ai_control!

      described_class.perform_now(message.id)

      expect(process_service).not_to have_received(:perform)
      expect(message.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'does not re-dispatch an attempted message on a duplicate job' do
      message = captain_message

      described_class.perform_now(message.id)
      described_class.perform_now(message.id)

      expect(process_service).to have_received(:perform).once
      expect(message.reload.additional_attributes['captain_delivery_state']).to eq('submitted')
    end

    it 'persists an unknown outcome and never retries a provider timeout blindly' do
      message = captain_message
      allow(process_service).to receive(:perform).and_raise(Net::ReadTimeout)

      described_class.perform_now(message.id)
      described_class.perform_now(message.id)

      expect(process_service).to have_received(:perform).once
      expect(message.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    end

    it 'does not mark a swallowed Telegram Personal gateway failure as submitted' do
      telegram_channel = create(:channel_telegram_personal, account: account)
      create(:captain_inbox, captain_assistant: assistant, inbox: telegram_channel.inbox)
      telegram_conversation = create(:conversation, account: account, inbox: telegram_channel.inbox, status: :pending)
      trigger = create(:message, message_type: :incoming, conversation: telegram_conversation)
      reply = create(:message, message_type: :outgoing, conversation: telegram_conversation, sender: assistant,
                               additional_attributes: { 'captain_delivery_fence' => {
                                 'assistant_id' => assistant.id,
                                 'control_generation' => telegram_conversation.current_captain_control_generation,
                                 'trigger_message_id' => trigger.id, 'kind' => 'reply'
                               } })
      gateway = instance_double(TelegramPersonal::GatewayClient)
      allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway)
      allow(gateway).to receive(:send_message!).and_raise(TelegramPersonal::GatewayClient::GatewayError, 'gateway unavailable')

      described_class.perform_now(reply.id)
      described_class.perform_now(reply.id)

      expect(gateway).to have_received(:send_message!).once
      expect(reply.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
      expect(reply).to be_failed
    end

    it 'allows a Captain handoff notification at the post-handoff generation only until a human reply' do
      incoming = create(:message, message_type: :incoming, conversation: conversation)
      conversation.activate_captain_human_control!(source: 'captain_handoff')
      message = captain_message(kind: 'handoff', trigger_id: incoming.id)

      described_class.perform_now(message.id)
      expect(process_service).to have_received(:perform).once

      second = captain_message(kind: 'handoff', trigger_id: incoming.id)
      create(:message, message_type: :outgoing, conversation: conversation, sender: create(:user, account: account))
      described_class.perform_now(second.id)
      expect(second.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
      expect(process_service).to have_received(:perform).once
    end

    it 'delivers a fenced resolution once, but cancels one whose control generation changed' do
      incoming = create(:message, message_type: :incoming, conversation: conversation)
      conversation.update!(status: :resolved)
      message = captain_message(kind: 'resolution', trigger_id: incoming.id)

      described_class.perform_now(message.id)
      expect(process_service).to have_received(:perform).once
      expect(message.reload.additional_attributes['captain_delivery_state']).to eq('submitted')

      stale = captain_message(kind: 'resolution', trigger_id: incoming.id)
      conversation.activate_captain_human_control!(source: 'manual_assignment')
      described_class.perform_now(stale.id)
      expect(stale.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
      expect(process_service).to have_received(:perform).once
    end

    it 'cancels a resolution notice after a newer incoming on an unlinked channel of the same contact' do
      incoming = create(:message, message_type: :incoming, conversation: conversation)
      conversation.update!(status: :resolved)
      notice = captain_message(kind: 'resolution', trigger_id: incoming.id)
      account.disable_features!('communication_threads')
      other_channel = create(:channel_widget, account: account)
      other_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox)
      other_conversation = create(:conversation, account: account, contact: conversation.contact,
                                                inbox: other_channel.inbox, contact_inbox: other_contact_inbox)
      create(:message, message_type: :incoming, conversation: other_conversation)
      account.enable_features!('communication_threads')
      Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
      expect(other_conversation.reload.communication_thread).to be_nil

      described_class.perform_now(notice.id)

      expect(process_service).not_to have_received(:perform)
      expect(notice.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'delivers a pre-fence Captain handoff notification unless a human has replied afterwards' do
      message = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant)
      described_class.perform_now(message.id)
      expect(process_service).to have_received(:perform).once

      later = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant)
      create(:message, message_type: :outgoing, conversation: conversation, sender: create(:user, account: account))
      described_class.perform_now(later.id)
      expect(later.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
      expect(process_service).to have_received(:perform).once
    end

    it 'cancels an unfenced pre-upgrade reply after manual assignment without a human message' do
      legacy_reply = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant)
      conversation.activate_captain_human_control!(source: 'manual_assignment')

      described_class.perform_now(legacy_reply.id)

      expect(process_service).not_to have_received(:perform)
      expect(legacy_reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'keeps an unfenced old reply cancelled after AI regains control' do
      legacy_reply = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant)
      conversation.activate_captain_human_control!(source: 'manual_assignment')
      conversation.prepare_captain_ai_control!

      described_class.perform_now(legacy_reply.id)

      expect(process_service).not_to have_received(:perform)
      expect(legacy_reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end

    it 'preserves a legacy handoff notice created after an actual handoff' do
      expect(conversation.bot_handoff!(actor: assistant, source: 'captain')).to eq(:applied)
      legacy_notice = create(:message, message_type: :outgoing, conversation: conversation, sender: assistant)

      described_class.perform_now(legacy_notice.id)

      expect(process_service).to have_received(:perform).once
    end
  end
end
