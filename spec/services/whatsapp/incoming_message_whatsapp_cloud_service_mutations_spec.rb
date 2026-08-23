require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageWhatsappCloudService do
  subject(:perform) { described_class.new(inbox: channel.inbox, params: params, outgoing_echo: false).perform }

  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:conversation) { create(:conversation, inbox: channel.inbox) }
  let!(:target_message) do
    create(
      :message,
      conversation: conversation,
      inbox: channel.inbox,
      message_type: :incoming,
      source_id: 'wamid.original',
      content: 'Исходный текст'
    )
  end
  let(:event) do
    {
      id: 'wamid.event',
      from: '15551234567',
      timestamp: '1700000100',
      type: event_type
    }.merge(event_payload)
  end
  let(:params) do
    {
      entry: [{
        changes: [{
          field: 'messages',
          value: {
            metadata: { phone_number_id: channel.provider_config['phone_number_id'] },
            contacts: [{ profile: { name: 'Cloud user' }, wa_id: event[:from] }],
            messages: [event]
          }
        }]
      }]
    }.with_indifferent_access
  end

  context 'with a reaction event' do
    let(:event_type) { 'reaction' }
    let(:event_payload) { { reaction: { message_id: target_message.source_id, emoji: '👍' } } }

    it 'persists the reaction on the original message for dashboard rendering' do
      perform

      expect(target_message.reload.content_attributes.dig('whatsapp_reactions', '15551234567')).to include(
        'emoji' => '👍',
        'event_id' => 'wamid.event'
      )
    end

    it 'does not let an older reaction overwrite a newer reaction from the same actor' do
      target_message.update!(
        content_attributes: {
          'whatsapp_reactions' => {
            '15551234567' => { 'emoji' => '🔥', 'event_id' => 'wamid.newer', 'timestamp' => '1700000200' }
          }
        }
      )

      perform

      expect(target_message.reload.content_attributes.dig('whatsapp_reactions', '15551234567')).to include(
        'emoji' => '🔥',
        'event_id' => 'wamid.newer'
      )
    end

    it 'keeps a removal tombstone so a delayed older reaction cannot reappear' do
      removal_params = params.deep_dup
      removal_event = removal_params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
      removal_event[:id] = 'wamid.removal'
      removal_event[:timestamp] = '1700000200'
      removal_event[:reaction][:emoji] = ''

      described_class.new(inbox: channel.inbox, params: removal_params, outgoing_echo: false).perform
      perform

      attributes = target_message.reload.content_attributes
      expect(attributes.fetch('whatsapp_reactions', {})).not_to have_key('15551234567')
      expect(attributes.dig('whatsapp_reaction_events', '15551234567')).to include(
        'event_id' => 'wamid.removal',
        'timestamp' => '1700000200'
      )
    end

    it 'keeps a missing-target reaction tenant-scoped and replays it later' do
      other_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      other_conversation = create(:conversation, inbox: other_channel.inbox)
      other_target = create(
        :message,
        conversation: other_conversation,
        inbox: other_channel.inbox,
        source_id: target_message.source_id
      )
      target_message.destroy!

      perform

      expect(other_target.reload.content_attributes['whatsapp_reactions']).to be_blank
      pending = Whatsapp::PendingMessageMutation.find_by!(inbox: channel.inbox, event_id: 'wamid.event')
      replacement = create(
        :message,
        conversation: conversation,
        inbox: channel.inbox,
        source_id: 'wamid.original'
      )

      Whatsapp::IncomingMessageMutationService.replay_pending_for(replacement)

      expect(replacement.reload.content_attributes.dig('whatsapp_reactions', '15551234567', 'emoji')).to eq('👍')
      expect { pending.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'with an edit event' do
    let(:event_type) { 'edit' }
    let(:event_payload) do
      {
        edit: {
          original_message_id: target_message.source_id,
          message: { type: 'text', text: { body: 'Исправленный текст' } }
        }
      }
    end

    it 'updates the original message and records edit metadata' do
      perform

      expect(target_message.reload).to have_attributes(content: 'Исправленный текст')
      expect(target_message.content_attributes).to include(
        'edited' => true,
        'whatsapp_edit_event_id' => 'wamid.event'
      )
    end

    it 'does not let an older edit overwrite newer content' do
      target_message.update!(
        content: 'Более новый текст',
        content_attributes: {
          'edited' => true,
          'whatsapp_edit_event_id' => 'wamid.newer',
          'whatsapp_edited_at' => '1700000200'
        }
      )

      perform

      expect(target_message.reload).to have_attributes(content: 'Более новый текст')
      expect(target_message.content_attributes['whatsapp_edit_event_id']).to eq('wamid.newer')
    end

    it 'persists and replays the edit when the original message arrives later' do
      target_message.destroy!

      expect { perform }.to change(Whatsapp::PendingMessageMutation, :count).by(1)
      expect do
        described_class.new(inbox: channel.inbox, params: params, outgoing_echo: false).perform
      end.not_to change(Whatsapp::PendingMessageMutation, :count)

      pending = Whatsapp::PendingMessageMutation.find_by!(inbox: channel.inbox, event_id: 'wamid.event')
      expect(pending).to have_attributes(
        target_source_id: 'wamid.original',
        mutation_type: 'edit',
        provider_timestamp: 1_700_000_100
      )

      original_params = params.deep_dup
      original_event = original_params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
      original_event.replace(
        id: 'wamid.original',
        from: '15551234567',
        timestamp: '1700000000',
        type: 'text',
        text: { body: 'Исходный текст' }
      )

      described_class.new(inbox: channel.inbox, params: original_params, outgoing_echo: false).perform

      recovered = channel.inbox.messages.find_by!(source_id: 'wamid.original')
      expect(recovered.content).to eq('Исправленный текст')
      expect(recovered.content_attributes).to include(
        'edited' => true,
        'whatsapp_edit_event_id' => 'wamid.event'
      )
      expect(Whatsapp::PendingMessageMutation.where(inbox: channel.inbox)).to be_empty
    end

    it 'broadcasts a later edit for a message that originated in imported history' do
      target_message.update!(content_attributes: { imported_history: true })
      dispatcher = Rails.configuration.dispatcher
      allow(dispatcher).to receive(:dispatch)

      perform

      expect(dispatcher).to have_received(:dispatch).with(
        Events::Types::MESSAGE_UPDATED,
        kind_of(Time),
        hash_including(message: target_message)
      )
    end
  end

  context 'with a revoke event' do
    let(:event_type) { 'revoke' }
    let(:event_payload) { { revoke: { original_message_id: target_message.source_id } } }

    it 'soft-deletes the original message' do
      perform

      expect(target_message.reload.content).to eq(I18n.t('conversations.messages.deleted'))
      expect(target_message.content_attributes).to include(
        'deleted' => true,
        'whatsapp_revoke_event_id' => 'wamid.event'
      )
    end

    it 'does not let an older revoke remove a newer edit' do
      target_message.update!(
        content: 'Более новый текст',
        content_attributes: {
          'edited' => true,
          'whatsapp_edit_event_id' => 'wamid.newer',
          'whatsapp_edited_at' => '1700000200'
        }
      )

      perform

      expect(target_message.reload).to have_attributes(content: 'Более новый текст')
      expect(target_message.content_attributes['deleted']).to be_nil
    end

    it 'replays a revoke that arrived before its original message' do
      target_message.destroy!
      perform
      replacement = create(
        :message,
        conversation: conversation,
        inbox: channel.inbox,
        source_id: 'wamid.original',
        content: 'Original'
      )

      Whatsapp::IncomingMessageMutationService.replay_pending_for(replacement)

      expect(replacement.reload.content).to eq(I18n.t('conversations.messages.deleted'))
      expect(replacement.content_attributes).to include('deleted' => true, 'whatsapp_revoke_event_id' => 'wamid.event')
      expect(Whatsapp::PendingMessageMutation.where(inbox: channel.inbox)).to be_empty
    end
  end

  context 'with an unsupported event' do
    let(:event_type) { 'unsupported' }
    let(:event_payload) do
      {
        errors: [{
          code: 131_051,
          title: 'Message type unknown',
          message: 'Message type unknown',
          error_data: { details: 'Message type is currently not supported.' }
        }],
        unsupported: { type: 'poll_update' }
      }
    end

    it 'persists a visible placeholder using the official Meta error details' do
      expect { perform }.to change { channel.inbox.messages.count }.by(1)

      message = channel.inbox.messages.find_by!(source_id: 'wamid.event')
      expect(message.content).to include('Message type is currently not supported.')
      expect(message.content_attributes).to include(
        'whatsapp_unavailable_message' => true,
        'whatsapp_error_code' => 131_051,
        'whatsapp_error_title' => 'Message type unknown',
        'whatsapp_error_message' => 'Message type is currently not supported.'
      )
    end
  end
end
