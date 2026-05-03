require 'rails_helper'

RSpec.describe Captain::Tools::Operations::TouchOperations do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let(:signed_blob_id) { account_owned_blob.signed_id }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end

  describe '#create_touch' do
    it 'creates a pending touch for the current conversation by default' do
      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Follow up tomorrow',
        scheduled_at: 1.day.from_now.iso8601
      )

      expect(touch).to be_persisted
      expect(touch.status).to eq('pending')
      expect(touch.remindable).to eq(conversation)
      expect(touch.target_inbox).to eq(conversation.inbox)
      expect(touch.metadata['touch_source']).to eq('captain')
    end

    it 'supports relative scheduling for linked deal context' do
      deal = create(:crm_deal, account: account, expected_close_on: Date.current + 3.days)
      create(:crm_deal_contact, deal: deal, contact: conversation.contact, account: account)
      allow(Captain::ContextFields).to receive(:deal_for).and_return(deal)

      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Close date follow-up',
        remindable_kind: 'deal',
        relative_anchor: 'deal.expected_close_on',
        relative_offset_minutes: -60
      )

      expect(touch.remindable).to eq(deal)
      expect(touch.timing_mode).to eq('relative')
      expect(touch.relative_anchor).to eq('deal.expected_close_on')
      expect(touch.relative_offset_seconds).to eq(-3600)
    end

    it 'defaults relative offsets from now to the touch creation time' do
      freeze_time do
        touch = described_class.new(
          assistant: assistant,
          conversation: conversation,
          actor: user
        ).create_touch(
          body: 'Ping in three minutes',
          relative_offset_minutes: 3
        )

        expect(touch.relative_anchor).to eq('touch.created_at')
        expect(touch.relative_offset_seconds).to eq(180)
        expect(touch.scheduled_at).to be_within(1.second).of(3.minutes.from_now)
      end
    end

    it 'uses the same template detection pattern for touch bodies' do
      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Follow up with {{contact.name}}',
        scheduled_at: 1.day.from_now.iso8601
      )

      expect(touch.text_mode).to eq('dynamic')
    end

    it 'stores selected attachment ids on the reminder so execution uses the native message builder pipeline' do
      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Follow up with a file',
        scheduled_at: 1.day.from_now.iso8601,
        attachment_ids: [signed_blob_id]
      )

      expect(touch.attachments).to eq([signed_blob_id])
      expect(touch.files.blobs).to contain_exactly(account_owned_blob)
    end

    it 'allows attachment-only free_text touches' do
      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: nil,
        scheduled_at: 1.day.from_now.iso8601,
        attachment_ids: [signed_blob_id]
      )

      expect(touch.content_kind).to eq('free_text')
      expect(touch.body).to be_blank
      expect(touch.attachments).to eq([signed_blob_id])
    end

    it 'materializes selected artifact ids before storing reminder attachments' do
      materializer = instance_double(Captain::Tools::HttpArtifactMaterializer)
      allow(Captain::Tools::HttpArtifactMaterializer).to receive(:new)
        .with(account: account, assistant: assistant)
        .and_return(materializer)
      allow(materializer).to receive(:materialize!).with('opaque-artifact-id').and_return(signed_blob_id)

      touch = described_class.new(
        assistant: assistant,
        conversation: conversation,
        actor: user
      ).create_touch(
        body: 'Follow up with selected artifact',
        scheduled_at: 1.day.from_now.iso8601,
        artifact_ids: ['opaque-artifact-id']
      )

      expect(touch.attachments).to eq([signed_blob_id])
      expect(materializer).to have_received(:materialize!).with('opaque-artifact-id')
    end

    it 'raises when the selected context is unavailable' do
      operation = described_class.new(assistant: assistant, conversation: conversation, actor: user)

      expect do
        operation.create_touch(
          body: 'Appointment reminder',
          remindable_kind: 'appointment',
          scheduled_at: 1.day.from_now.iso8601
        )
      end.to raise_error(ArgumentError, 'Current appointment is not available')
    end

    it 'creates a channel_template touch without requiring a body' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: conversation.contact,
                                                    contact_inbox: contact_inbox)
      template_params = {
        name: 'sample_shipping_confirmation',
        language: 'en_US',
        namespace: '23423423_2342423_324234234_2343224',
        processed_params: { '1' => '2' }
      }

      touch = described_class.new(
        assistant: assistant,
        conversation: whatsapp_conversation,
        actor: user
      ).create_touch(
        content_kind: 'channel_template',
        template_params: template_params,
        scheduled_at: 1.day.from_now.iso8601
      )

      expect(touch.content_kind).to eq('channel_template')
      expect(touch.body).to be_blank
      expect(touch.template_params).to include('name' => 'sample_shipping_confirmation', 'language' => 'en_US')
      expect(touch.metadata['delivery_policy']).to include('delivery_mode' => 'channel_template', 'requires_template' => true)
    end

    it 'fails fast for scheduled WhatsApp Business free text when the reply window will be closed' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: conversation.contact,
                                                    contact_inbox: contact_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: whatsapp_conversation, message_type: 'incoming', created_at: 1.hour.ago)
      operation = described_class.new(assistant: assistant, conversation: whatsapp_conversation, actor: user)

      expect do
        operation.create_touch(
          body: 'Scheduled free text',
          scheduled_at: 25.hours.from_now.iso8601
        )
      end.to raise_error(ArgumentError, /approved channel_template/)
    end

    it 'fails fast for relative WhatsApp Business free text when the reply window will be closed at delivery time' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(
        :conversation,
        account: account,
        inbox: whatsapp_inbox,
        contact: conversation.contact,
        contact_inbox: contact_inbox
      )
      create(
        :message,
        account: account,
        inbox: whatsapp_inbox,
        conversation: whatsapp_conversation,
        message_type: 'incoming',
        created_at: 1.hour.ago
      )
      operation = described_class.new(assistant: assistant, conversation: whatsapp_conversation, actor: user)

      expect do
        operation.create_touch(
          body: 'Relative free text',
          relative_anchor: 'touch.created_at',
          relative_offset_minutes: 25.hours.in_minutes
        )
      end.to raise_error(ArgumentError, /approved channel_template/)
    end
  end
end
