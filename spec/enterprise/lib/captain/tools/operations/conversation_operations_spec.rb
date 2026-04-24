require 'rails_helper'

RSpec.describe Captain::Tools::Operations::ConversationOperations do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:actor) { create(:user, :administrator, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:operations) { described_class.new(assistant: assistant, conversation: conversation, actor: actor) }
  let(:signed_blob_id) { account_owned_blob.signed_id }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end

  describe '#send_message_to_conversation' do
    it 'sends selected attachment ids through the native message builder pipeline' do
      message = operations.send_message_to_conversation(
        conversation_id: conversation.id,
        content: 'Here is the file',
        attachment_ids: [signed_blob_id]
      )

      expect(message).to be_outgoing
      expect(message.content).to eq('Here is the file')
      expect(message.attachments.size).to eq(1)
      expect(message.attachments.first.file_type).to eq('image')
      expect(message.attachments.first.file.blob.signed_id).to eq(signed_blob_id)
    end

    it 'allows attachment-only outgoing messages when a selected file is present' do
      message = operations.send_message_to_conversation(
        conversation_id: conversation.id,
        content: '',
        attachment_ids: [signed_blob_id]
      )

      expect(message).to be_outgoing
      expect(message.content).to be_blank
      expect(message.attachments.first.file_type).to eq('image')
    end

    it 'rejects direct attachment ids that are not scoped to the current account' do
      other_account_blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open('spec/assets/avatar.png', 'rb'),
        filename: 'avatar.png',
        content_type: 'image/png',
        metadata: { 'account_id' => create(:account).id }
      )

      expect do
        operations.send_message_to_conversation(
          conversation_id: conversation.id,
          content: 'Wrong account file',
          attachment_ids: [other_account_blob.signed_id]
        )
      end.to raise_error(ArgumentError, 'Attachment does not belong to the current account')
    end

    it 'materializes selected artifact ids before sending attachments' do
      materializer = instance_double(Captain::Tools::HttpArtifactMaterializer)
      allow(Captain::Tools::HttpArtifactMaterializer).to receive(:new)
        .with(account: account, assistant: assistant)
        .and_return(materializer)
      allow(materializer).to receive(:materialize!).with('opaque-artifact-id').and_return(signed_blob_id)

      message = operations.send_message_to_conversation(
        conversation_id: conversation.id,
        content: 'Selected artifact',
        artifact_ids: ['opaque-artifact-id']
      )

      expect(message.attachments.first.file.blob.signed_id).to eq(signed_blob_id)
      expect(materializer).to have_received(:materialize!).with('opaque-artifact-id')
    end

    it 'fails fast when WhatsApp Business free text is outside the reply window' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      whatsapp_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: whatsapp_contact_inbox)
      whatsapp_operations = described_class.new(assistant: assistant, conversation: whatsapp_conversation, actor: actor)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: whatsapp_conversation, message_type: 'incoming',
                       created_at: 25.hours.ago)

      expect do
        whatsapp_operations.send_message_to_conversation(
          conversation_id: whatsapp_conversation.id,
          content: 'Outside window free text'
        )
      end.to raise_error(ArgumentError, /approved channel_template/)
    end

    it 'sends an approved WhatsApp channel template outside the reply window' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      whatsapp_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: whatsapp_contact_inbox)
      whatsapp_operations = described_class.new(assistant: assistant, conversation: whatsapp_conversation, actor: actor)
      template_params = {
        name: 'sample_shipping_confirmation',
        language: 'en_US',
        namespace: '23423423_2342423_324234234_2343224',
        processed_params: { '1' => '2' }
      }

      message = whatsapp_operations.send_message_to_conversation(
        conversation_id: whatsapp_conversation.id,
        content_kind: 'channel_template',
        template_params: template_params
      )

      expect(message).to be_outgoing
      expect(message.content).to be_blank
      expect(message.additional_attributes['template_params']).to include('name' => 'sample_shipping_confirmation', 'language' => 'en_US')
      expect(message.additional_attributes['delivery_policy']).to include('delivery_mode' => 'channel_template', 'requires_template' => true)
    end
  end
end
