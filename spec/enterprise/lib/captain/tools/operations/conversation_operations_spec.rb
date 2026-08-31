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
  let(:second_signed_blob_id) { second_account_owned_blob.signed_id }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end
  let(:second_account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar-2.png',
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

    it 'splits multiple attachments into sequential WhatsApp messages' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      whatsapp_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact,
                                                    contact_inbox: whatsapp_contact_inbox)
      whatsapp_operations = described_class.new(assistant: assistant, conversation: whatsapp_conversation, actor: actor)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: whatsapp_conversation, message_type: 'incoming',
                       created_at: 1.hour.ago)

      message = whatsapp_operations.send_message_to_conversation(
        conversation_id: whatsapp_conversation.id,
        content: 'Here are the files',
        attachment_ids: [signed_blob_id, second_signed_blob_id]
      )

      outgoing_messages = whatsapp_conversation.reload.messages.outgoing.where(private: false).last(2)
      expect(message).to eq(outgoing_messages.first)
      expect(outgoing_messages.map(&:content)).to eq(['Here are the files', nil])
      expect(outgoing_messages.map { |outgoing_message| outgoing_message.attachments.size }).to eq([1, 1])
      expect(outgoing_messages.map { |outgoing_message| outgoing_message.attachments.first.file.filename.to_s })
        .to eq(%w[avatar.png avatar-2.png])
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

  describe '#assign_conversation' do
    it 'records assignee and team activities with the Captain actor' do
      assignee = create(:user, account: account)
      team = create(:team, account: account)
      create(:team_member, team: team, user: assignee)

      operations.assign_conversation(
        conversation_id: conversation.display_id,
        assignee_id: assignee.id,
        team_id: team.id
      )

      expect(Conversations::ActivityMessageJob).to have_been_enqueued.with(
        conversation,
        hash_including(
          content: I18n.t(
            'conversations.activity.assignee.assigned',
            assignee_name: assignee.name,
            user_name: actor.name
          )
        )
      )
      expect(Conversations::ActivityMessageJob).to have_been_enqueued.with(
        conversation,
        hash_including(
          content: I18n.t(
            'conversations.activity.team.assigned',
            team_name: team.name,
            user_name: actor.name
          )
        )
      )
    end
  end

  describe '#resolve_conversation' do
    it 'records the configured assistant completion outcome' do
      assistant.update!(
        config: {
          'outcome_reason_settings' => {
            'completion_reasons' => [
              { 'id' => 'customer_confirmed', 'label' => 'Customer confirmed' },
              { 'id' => 'other', 'label' => 'Other' }
            ]
          }
        }
      )

      operations.resolve_conversation(
        reason: 'Customer confirmed resolution',
        status_reason: 'customer_confirmed'
      )

      expect(conversation.reload).to be_resolved
      expect(conversation.status_transitions.last.reason).to eq('Customer confirmed')
    end

    it 'records other without treating the explanation as a stable outcome id' do
      assistant.update!(
        config: {
          'outcome_reason_settings' => {
            'completion_reasons' => [{ 'id' => 'other', 'label' => 'Other' }]
          }
        }
      )

      operations.resolve_conversation(reason: 'free-text internal explanation')

      expect(conversation.reload).to be_resolved
      expect(conversation.status_transitions.last.reason).to eq('Other')
      expect(conversation.status_transitions.last.metadata).to include('outcome_reason_id' => 'other')
    end
  end

  describe '#handoff' do
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: 'pending') }

    it 'records the configured assistant handoff outcome' do
      assistant.update!(
        config: {
          'outcome_reason_settings' => {
            'handoff_reasons' => [
              { 'id' => 'needs_agent', 'label' => 'Needs agent' },
              { 'id' => 'other', 'label' => 'Other' }
            ]
          }
        }
      )

      operations.handoff(status_reason: 'needs_agent', reason: 'Клиенту требуется помощь сотрудника')

      expect(conversation.reload).to be_open
      expect(conversation.status_transitions.last.reason).to eq('Needs agent')
    end

    it 'requires a concrete explanation before recording an agent-scoped other handoff' do
      assistant.update!(
        config: {
          'outcome_reason_settings' => {
            'handoff_reasons' => [{ 'id' => 'other', 'label' => 'Другое' }]
          }
        }
      )
      captain_operations = described_class.new(assistant: assistant, conversation: conversation)

      expect do
        captain_operations.handoff(status_reason: 'other')
      end.to raise_error(ArgumentError, 'A specific handoff explanation is required')
        .and not_change(Message, :count)

      captain_operations.handoff(
        status_reason: 'other',
        reason: 'Клиент просит нестандартную отсрочку платежа'
      )

      expect(conversation.reload).to be_open
      expect(conversation.status_transitions.last.metadata).to include(
        'outcome_reason_id' => 'other',
        'outcome_reason_type' => 'handoff',
        'outcome_reason_explanation' => 'Клиент просит нестандартную отсрочку платежа'
      )
      expect(conversation.messages.private.last.content).to eq('Клиент просит нестандартную отсрочку платежа')
    end
  end
end
