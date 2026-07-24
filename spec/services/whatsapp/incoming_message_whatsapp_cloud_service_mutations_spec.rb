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

    it 'raises a retryable error when the original message has not arrived yet' do
      target_message.destroy!

      expect { perform }.to raise_error(
        Whatsapp::IncomingMessageMutationService::TargetNotFoundError,
        /Original WhatsApp message wamid.original/
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
