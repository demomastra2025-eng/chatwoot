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
end
