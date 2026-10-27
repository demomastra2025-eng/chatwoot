# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::ChannelCapabilitiesBuilder do
  describe '#perform' do
    let(:account) do
      create(:account).tap { |record| record.enable_features!('communication_threads') }
    end

    it 'returns channel metadata and generic reply capabilities' do
      conversation = create(:conversation, account: account)
      link = conversation.communication_thread_conversation

      payload = described_class.new(links: [link]).perform.first

      expect(payload).to include(
        conversation_id: conversation.display_id,
        inbox_id: conversation.inbox_id,
        inbox_name: conversation.inbox.name,
        source_id: conversation.contact_inbox.source_id,
        contact_inbox_id: conversation.contact_inbox_id,
        channel_profile: nil,
        channel: conversation.inbox.channel_type,
        medium: conversation.inbox.channel.respond_to?(:medium) ? conversation.inbox.channel.medium : nil,
        provider: conversation.inbox.channel.class.name,
        status: conversation.status,
        can_reply: conversation.can_reply?,
        can_send_text: conversation.can_reply?,
        can_send_attachments: conversation.can_reply?,
        can_call: false,
        requires_template: false,
        reply_window_open: conversation.can_reply?,
        reply_window_closes_at: nil,
        allowed_content_kinds: ['free_text'],
        delivery_mode: conversation.can_reply? ? 'free_text' : nil,
        reauthorization_required: false,
        disabled: !conversation.can_reply?,
        disabled_reason: conversation.can_reply? ? nil : 'not_replyable',
        primary: link.primary?,
        last_activity_at: conversation.last_activity_at.to_i
      )
    end

    it 'uses preloaded unread and incoming-message state without per-channel message queries' do
      conversation = create(:conversation, account: account)
      link = conversation.communication_thread_conversation
      last_incoming_message_at = 1.hour.ago

      expect(conversation).not_to receive(:unread_incoming_messages_count)
      expect(conversation).not_to receive(:can_reply?)
      payload = described_class.new(
        links: [link],
        unread_counts: { conversation.id => 7 },
        last_incoming_message_timestamps: { conversation.id => last_incoming_message_at }
      ).perform.first

      expect(payload[:unread_count]).to eq(7)
    end

    it 'returns contact-facing channel identity metadata without replacing inbox metadata' do
      contact = create(:contact, account: account)
      inbox = create(:inbox, account: account, name: 'Business Telegram')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'client-source-id')
      create(:contact_channel_profile, contact_inbox: contact_inbox, username: 'client_login', identifier: 'telegram-user-id')
      conversation = create(:conversation, account: account, contact: contact, inbox: inbox, contact_inbox: contact_inbox)
      link = conversation.communication_thread_conversation

      payload = described_class.new(links: [link]).perform.first

      expect(payload).to include(
        inbox_name: 'Business Telegram',
        source_id: 'client-source-id',
        contact_inbox_id: contact_inbox.id
      )
      expect(payload[:channel_profile]).to include(
        username: 'client_login',
        identifier: 'telegram-user-id',
        source_id: 'client-source-id'
      )
    end

    it 'returns provider-aware WhatsApp template requirements outside the reply window' do
      contact = create(:contact, account: account)
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: whatsapp_inbox,
        contact_inbox: contact_inbox
      )
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: 'incoming', created_at: 25.hours.ago)
      link = conversation.communication_thread_conversation

      payload = described_class.new(links: [link]).perform.first

      expect(payload).to include(
        provider: whatsapp_inbox.channel.provider,
        can_reply: false,
        can_send_text: false,
        can_send_attachments: false,
        requires_template: true,
        reply_window_open: false,
        allowed_content_kinds: ['channel_template'],
        delivery_mode: nil,
        disabled: false,
        disabled_reason: 'template_required'
      )
      expect(payload[:delivery_policy]).to include(requires_template: true, provider: whatsapp_inbox.channel.provider)
      expect(payload[:reply_window_closes_at]).to be_present
    end

    it 'marks voice channels as callable but not text-sendable' do
      contact = create(:contact, account: account)
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox)
      conversation = create(:conversation, account: account, contact: contact, inbox: voice_inbox, contact_inbox: contact_inbox)
      link = conversation.communication_thread_conversation

      payload = described_class.new(links: [link]).perform.first

      expect(payload).to include(
        channel: 'Channel::Voice',
        can_reply: true,
        can_send_text: false,
        can_send_attachments: false,
        can_call: true,
        disabled: false,
        disabled_reason: nil
      )
    end

    it 'marks linked WhatsApp Cloud channels callable when WhatsApp calling is enabled' do
      account.enable_features!('whatsapp_call')
      contact = create(:contact, :with_phone_number, account: account)
      whatsapp_channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        provider_config: { 'calling_enabled' => true },
        sync_templates: false,
        validate_provider_config: false
      )
      whatsapp_inbox = whatsapp_channel.inbox
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: whatsapp_inbox,
        contact_inbox: contact_inbox
      )
      create(
        :message,
        account: account,
        inbox: whatsapp_inbox,
        conversation: conversation,
        message_type: 'incoming'
      )
      link = conversation.communication_thread_conversation

      payload = described_class.new(links: [link]).perform.first

      expect(payload).to include(
        channel: 'Channel::Whatsapp',
        provider: 'whatsapp_cloud',
        can_reply: true,
        can_send_text: true,
        can_send_attachments: true,
        can_call: true,
        disabled: false,
        disabled_reason: nil
      )
    end

    it 'keeps reauthorization as a warning without disabling a replyable linked channel' do
      stub_request(:post, /graph.facebook.com/)
      facebook_channel = create(:channel_facebook_page, account: account)
      allow(facebook_channel).to receive(:send_channel_reauthorization_email)
      facebook_inbox = create(:inbox, account: account, channel: facebook_channel)
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: facebook_inbox)
      conversation = create(:conversation, account: account, contact: contact, inbox: facebook_inbox, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: facebook_inbox, conversation: conversation, message_type: 'incoming')
      facebook_channel.prompt_reauthorization!

      payload = described_class.new(links: [conversation.communication_thread_conversation]).perform.first

      expect(payload).to include(
        reauthorization_required: true,
        can_reply: true,
        can_send_text: true,
        can_send_attachments: true,
        disabled: false,
        disabled_reason: nil
      )
    end

    it 'deduplicates linked conversations by inbox for selector payloads' do
      contact = create(:contact, :with_email, account: account)
      inbox = create(:inbox, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      older_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: inbox,
        contact_inbox: contact_inbox,
        last_activity_at: 2.days.ago
      )
      newer_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: inbox,
        contact_inbox: contact_inbox,
        last_activity_at: 1.hour.ago
      )
      links = [older_conversation, newer_conversation].map { |conversation| conversation.reload.communication_thread_conversation }

      payload = described_class.new(links: links).perform

      expect(payload.pluck(:inbox_id)).to contain_exactly(inbox.id)
      expect(payload.first[:conversation_id]).to eq(newer_conversation.display_id)
      expect(described_class.new(links: links, deduplicate_linked: false).perform.pluck(:conversation_id)).to contain_exactly(
        older_conversation.display_id,
        newer_conversation.display_id
      )
    end

    it 'returns unlinked channel capability with target contact inbox aliases' do
      contact = create(:contact, :with_email, account: account)
      conversation = create(:conversation, account: account, contact: contact)
      email_inbox = create(:inbox, :with_email, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: email_inbox)
      link = conversation.communication_thread_conversation

      payload = described_class.new(
        links: [link],
        contact: contact,
        available_inboxes: [conversation.inbox, email_inbox],
        include_unlinked: true
      ).perform.find { |channel| channel[:inbox_id] == email_inbox.id }

      expect(payload).to include(
        conversation_id: nil,
        inbox_id: email_inbox.id,
        contact_inbox_id: contact_inbox.id,
        can_send_text: true,
        disabled: false,
        channel_key: "inbox:#{email_inbox.id}"
      )
    end

    it 'returns unlinked voice channels as call-only capabilities when the contact has a phone number' do
      contact = create(:contact, :with_phone_number, account: account)
      conversation = create(:conversation, account: account, contact: contact)
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox

      payload = described_class.new(
        links: [conversation.communication_thread_conversation],
        contact: contact,
        available_inboxes: [conversation.inbox, voice_inbox],
        include_unlinked: true
      ).perform.find { |channel| channel[:inbox_id] == voice_inbox.id }

      expect(payload).to include(
        conversation_id: nil,
        inbox_id: voice_inbox.id,
        channel: 'Channel::Voice',
        can_reply: true,
        can_send_text: false,
        can_send_attachments: false,
        can_call: true,
        disabled: false,
        disabled_reason: nil,
        channel_key: "inbox:#{voice_inbox.id}"
      )
    end

    describe 'the channels a person with no conversation can be written to first' do
      let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
      let(:whatsapp_inbox) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox }

      def unlinked_channels(inboxes, person: contact)
        described_class.new(links: [], contact: person, available_inboxes: inboxes, include_unlinked: true).perform
      end

      it 'offers the official WhatsApp by the phone number and asks for a template when the person never wrote', :aggregate_failures do
        channel = unlinked_channels([whatsapp_inbox]).first

        expect(channel).to include(
          conversation_id: nil, channel_key: "inbox:#{whatsapp_inbox.id}", requires_template: true, can_send_text: false,
          disabled_reason: 'template_required'
        )
      end

      it 'offers a Telegram bot only to a person who has already written to it: a bot cannot write first', :aggregate_failures do
        telegram_inbox = create(:channel_telegram, account: account).inbox
        person = create(:contact, account: account, additional_attributes: { 'social_telegram_user_id' => '555000111' })

        expect(unlinked_channels([telegram_inbox], person: person).pluck(:inbox_id)).to be_empty
        expect(unlinked_channels([telegram_inbox]).pluck(:inbox_id)).to be_empty

        create(:contact_inbox, contact: person, inbox: telegram_inbox, source_id: '555000111')

        expect(unlinked_channels([telegram_inbox], person: person).pluck(:inbox_id)).to eq([telegram_inbox.id])
      end

      it 'offers WhatsApp Web only to a person who has already written there', :aggregate_failures do
        web_inbox = create(:channel_whatsapp_web, account: account).inbox

        expect(unlinked_channels([web_inbox]).pluck(:inbox_id)).to be_empty

        create(:contact_inbox, contact: contact, inbox: web_inbox, source_id: '77011234567')
        channel = unlinked_channels([web_inbox]).first

        expect(channel).to include(inbox_id: web_inbox.id, can_send_text: true, disabled: false)
      end

      it 'lists a channel that needs a phone number as disabled, with the reason, for a person without one', :aggregate_failures do
        person = create(:contact, account: account, phone_number: nil)

        channel = unlinked_channels([whatsapp_inbox], person: person).first

        expect(channel).to include(inbox_id: whatsapp_inbox.id, can_send_text: false, disabled: true, disabled_reason: 'missing_contact_phone_number')
      end

      it 'asks for no template from a channel that cannot reach the person: a template does not give them a number', :aggregate_failures do
        person = create(:contact, account: account, phone_number: nil)

        channel = unlinked_channels([whatsapp_inbox], person: person).first

        expect(channel).to include(requires_template: false, can_reply: false, can_send_text: false, can_send_attachments: false)
      end

      it 'calls from a voice inbox when the person has a phone number' do
        voice_inbox = create(:channel_voice, :sipuni, account: account).inbox

        expect(unlinked_channels([voice_inbox]).first).to include(inbox_id: voice_inbox.id, can_call: true, can_send_text: false)
      end

      it 'puts the official WhatsApp first and a call last, in the same order every time', :aggregate_failures do
        voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
        email_inbox = create(:inbox, :with_email, account: account)
        sms_inbox = create(:channel_sms, account: account).inbox
        person = create(:contact, :with_email, account: account, phone_number: '+77011234567')

        inbox_ids = unlinked_channels([voice_inbox, email_inbox, sms_inbox, whatsapp_inbox], person: person).pluck(:inbox_id)

        expect(inbox_ids).to eq([whatsapp_inbox.id, sms_inbox.id, email_inbox.id, voice_inbox.id])
        expect(unlinked_channels([whatsapp_inbox, sms_inbox, email_inbox, voice_inbox], person: person).pluck(:inbox_id)).to eq(inbox_ids)
      end

      it 'does not list a chat channel that cannot be started by staff' do
        web_inbox = create(:channel_whatsapp_web, account: account).inbox
        instagram_inbox = create(:channel_instagram, account: account).inbox

        expect(unlinked_channels([web_inbox, instagram_inbox]).pluck(:inbox_id)).to be_empty
      end
    end
  end
end
