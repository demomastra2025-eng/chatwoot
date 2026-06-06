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
        contact_inbox_id: conversation.contact_inbox_id,
        channel: conversation.inbox.channel_type,
        medium: conversation.inbox.channel.respond_to?(:medium) ? conversation.inbox.channel.medium : nil,
        provider: conversation.inbox.channel.class.name,
        status: conversation.status,
        can_reply: conversation.can_reply?,
        can_send_text: conversation.can_reply?,
        can_send_attachments: conversation.can_reply?,
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

    it 'returns provider-aware WhatsApp template requirements outside the reply window' do
      contact = create(:contact, account: account)
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, contact: contact, inbox: whatsapp_inbox, contact_inbox: contact_inbox)
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

    it 'returns unlinked channel capability with target contact inbox aliases' do
      contact = create(:contact, :with_email, account: account)
      conversation = create(:conversation, account: account, contact: contact)
      email_inbox = create(:inbox, :with_email, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: email_inbox)
      link = conversation.communication_thread_conversation

      payload = described_class.new(
        links: [link],
        contact: contact,
        available_inboxes: [conversation.inbox, email_inbox]
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
  end
end
