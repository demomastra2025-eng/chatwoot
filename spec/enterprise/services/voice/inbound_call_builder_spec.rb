# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::InboundCallBuilder do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_voice, account: account, phone_number: '+15551239999') }
  let(:inbox) { channel.inbox }
  let(:from_number) { '+15550001111' }
  let(:to_number) { channel.phone_number }
  let(:call_sid) { 'CA1234567890abcdef' }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
  end

  def perform_builder
    described_class.perform!(
      account: account,
      inbox: inbox,
      from_number: from_number,
      call_sid: call_sid
    )
  end

  context 'when no existing conversation matches call_sid' do
    it 'creates a new inbound conversation with ringing status' do
      conversation = nil
      expect { conversation = perform_builder }.to change(account.conversations, :count).by(1)

      attrs = conversation.additional_attributes
      expect(conversation.identifier).to eq(call_sid)
      expect(attrs['call_direction']).to eq('inbound')
      expect(attrs['call_status']).to eq('ringing')
      expect(attrs['conference_sid']).to be_present
      expect(attrs.dig('meta', 'initiated_at')).to be_present
      expect(conversation.contact.phone_number).to eq(from_number)
    end

    it 'creates a single voice_call message marked as incoming' do
      conversation = perform_builder
      voice_message = conversation.messages.voice_calls.last

      expect(voice_message).to be_present
      expect(voice_message.message_type).to eq('incoming')
      data = voice_message.content_attributes['data']
      expect(data).to include(
        'call_sid' => call_sid,
        'status' => 'ringing',
        'call_direction' => 'inbound',
        'conference_sid' => conversation.additional_attributes['conference_sid'],
        'from_number' => from_number,
        'to_number' => inbox.channel.phone_number
      )
      expect(data['meta']['created_at']).to be_present
      expect(data['meta']['ringing_at']).to be_present
    end

    it 'can defer the voice message while preparing an atomic recovery conversation' do
      conversation = described_class.perform!(
        account: account,
        inbox: inbox,
        from_number: from_number,
        call_sid: call_sid,
        build_voice_message: false
      )

      expect(conversation.messages.voice_calls).to be_empty
    end

    it 'sets the contact name to the phone number for new callers' do
      conversation = perform_builder

      expect(conversation.contact.name).to eq(from_number)
    end

    it 'ensures the conversation has a display_id before building the conference SID' do
      allow(Voice::Conference::Name).to receive(:for).and_wrap_original do |original, conversation|
        expect(conversation.display_id).to be_present
        original.call(conversation)
      end

      perform_builder
    end

    it 'uses the same contact lock across inboxes for the same account and caller' do
      other_inbox = create(:inbox, account: account)
      builders = [inbox, other_inbox].map do |target_inbox|
        described_class.new(
          account: account,
          inbox: target_inbox,
          from_number: from_number,
          call_sid: call_sid
        )
      end
      lock_statements = []
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:execute).and_wrap_original do |method, statement, *args|
        lock_statements << statement if statement.include?('pg_advisory_xact_lock')
        method.call(statement, *args)
      end

      ActiveRecord::Base.transaction do
        builders.each { |builder| builder.send(:lock_call_identity!) }
      end

      expect(lock_statements.size).to eq(2)
      expect(lock_statements.uniq.size).to eq(1)
    end
  end

  context 'when a conversation already exists for the call_sid' do
    let(:contact) { create(:contact, account: account, phone_number: from_number) }
    let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: from_number) }
    let!(:existing_conversation) do
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        identifier: call_sid,
        additional_attributes: { 'call_direction' => 'outbound', 'conference_sid' => nil }
      )
    end
    let(:existing_message) do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: existing_conversation,
        message_type: :incoming,
        content_type: :voice_call,
        sender: contact,
        content_attributes: { 'data' => { 'call_sid' => call_sid, 'status' => 'queued' } }
      )
    end

    it 'reuses the conversation without creating a duplicate' do
      existing_message
      expect { perform_builder }.not_to change(account.conversations, :count)
      existing_conversation.reload
      expect(existing_conversation.additional_attributes['call_direction']).to eq('inbound')
      expect(existing_conversation.additional_attributes['call_status']).to eq('ringing')
    end

    it 'updates the existing voice call message instead of creating a new one' do
      existing_message
      expect { perform_builder }.not_to(change { existing_conversation.reload.messages.voice_calls.count })
      updated_message = existing_conversation.reload.messages.voice_calls.last

      data = updated_message.content_attributes['data']
      expect(data['status']).to eq('ringing')
      expect(data['call_direction']).to eq('inbound')
    end
  end

  context 'with native SIP provider' do
    let(:channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551239999') }
    let(:call_sid) { 'sipuni-new-inbound-call-1' }
    let(:contact) { create(:contact, account: account, phone_number: from_number) }
    let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: from_number) }
    let!(:existing_conversation) do
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        identifier: 'sipuni-previous-call',
        additional_attributes: {
          'call_direction' => 'inbound',
          'call_status' => 'completed',
          'telephony_call_ref' => 'sipuni-previous-call',
          'agent_id' => 123,
          'call_started_at' => 100,
          'call_ended_at' => 120,
          'call_duration' => 20,
          'recording_ref' => 'old-recording.wav',
          'recording' => { 'storage_key' => 'old-recording.wav' },
          'from_number' => '+15550000000',
          'to_number' => '+15559990000'
        }
      )
    end

    before do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: existing_conversation,
        message_type: :incoming,
        content_type: :voice_call,
        sender: contact,
        source_id: 'voice_call:sipuni-previous-call',
        content_attributes: { 'data' => { 'call_sid' => 'sipuni-previous-call', 'status' => 'completed' } }
      )
    end

    it 'reuses the latest open contact conversation and creates a separate bubble for the new call' do
      expect { perform_builder }.not_to(change { account.conversations.where(inbox_id: inbox.id, contact_id: contact.id).count })

      existing_conversation.reload
      voice_messages = existing_conversation.messages.voice_calls.order(:created_at, :id)

      aggregate_failures do
        expect(existing_conversation.identifier).to eq('sipuni-previous-call')
        expect(existing_conversation).to be_open
        expect(existing_conversation.additional_attributes).to include(
          'call_direction' => 'inbound',
          'call_status' => 'ringing',
          'telephony_call_ref' => call_sid,
          'from_number' => from_number,
          'to_number' => channel.phone_number
        )
        expect(existing_conversation.additional_attributes).not_to have_key('agent_id')
        expect(existing_conversation.additional_attributes).not_to have_key('call_started_at')
        expect(existing_conversation.additional_attributes).not_to have_key('call_ended_at')
        expect(existing_conversation.additional_attributes).not_to have_key('call_duration')
        expect(existing_conversation.additional_attributes).not_to have_key('recording_ref')
        expect(existing_conversation.additional_attributes).not_to have_key('recording')
        expect(voice_messages.count).to eq(2)
        expect(voice_messages.last.source_id).to eq("voice_call:#{call_sid}")
        expect(voice_messages.last.content_attributes.dig('data', 'call_sid')).to eq(call_sid)
        expect(voice_messages.first.content_attributes.dig('data', 'call_sid')).to eq('sipuni-previous-call')
      end
    end

    it 'reuses the canonical contact inbox when concurrent contact lookup returns a duplicate contact' do
      duplicate_contact = create(:contact, account: account)
      contacts_scope = account.contacts
      allow(account).to receive(:contacts).and_return(contacts_scope)
      allow(contacts_scope).to receive(:find_or_create_by!).and_return(duplicate_contact)

      expect { perform_builder }.not_to change(ContactInbox, :count)

      conversation = account.conversations.order(:id).last
      expect(conversation).to eq(existing_conversation)
      expect(conversation.contact).to eq(contact)
      expect(conversation.contact_inbox).to eq(contact_inbox)
    end

    it 'rejects a canonical contact inbox linked to another account' do
      foreign_contact = create(:contact, account: create(:account))
      contact_inbox.update_column(:contact_id, foreign_contact.id) # rubocop:disable Rails/SkipsModelValidations

      expect { perform_builder }.to raise_error(ArgumentError, 'contact inbox must belong to account')
      expect(existing_conversation.reload.contact).to eq(contact)
    end

    it 'restores a missing contact inbox on the reusable native SIP conversation' do
      existing_conversation.update_column(:contact_inbox_id, nil) # rubocop:disable Rails/SkipsModelValidations

      expect { perform_builder }.not_to raise_error

      expect(existing_conversation.reload.contact_inbox).to eq(contact_inbox)
      expect(existing_conversation.messages.voice_calls.where(source_id: "voice_call:#{call_sid}").count).to eq(1)
    end

    it 'rejects a reusable conversation linked to a different contact inbox' do
      foreign_contact = create(:contact, account: account)
      foreign_contact_inbox = create(:contact_inbox, contact: foreign_contact, inbox: inbox, source_id: '+155****8181')
      existing_conversation.update_column(:contact_inbox_id, foreign_contact_inbox.id) # rubocop:disable Rails/SkipsModelValidations
      original_message_count = existing_conversation.messages.count

      expect { perform_builder }.to raise_error(ArgumentError, 'conversation does not match voice context')
      expect(existing_conversation.reload.messages.count).to eq(original_message_count)
    end

    it 'creates a dedicated conversation when reuse is disabled for late recovery' do
      original_attributes = existing_conversation.additional_attributes.deep_dup
      recovered_conversation = nil

      expect do
        recovered_conversation = described_class.perform!(
          account: account,
          inbox: inbox,
          from_number: from_number,
          call_sid: call_sid,
          reuse_existing_conversation: false
        )
      end.to change(account.conversations, :count).by(1)

      expect(recovered_conversation).not_to eq(existing_conversation)
      expect(recovered_conversation.identifier).to eq(call_sid)
      expect(recovered_conversation.contact).to eq(contact)
      expect(recovered_conversation.contact_inbox).to eq(contact_inbox)
      expect(existing_conversation.reload.additional_attributes).to eq(original_attributes)
    end
  end

  context 'with a provider-owned SIP provider' do
    let(:provider) { 'sipuni' }
    let(:call_sid) { "#{provider}-new-inbound-call-1" }
    let(:provider_connection) { create(:telephony_provider_connection, account: account, provider_kind: provider) }
    let(:channel) do
      create(
        :channel_voice,
        account: account,
        phone_number: '+15551239999',
        provider: provider,
        provider_config: {
          number_ref: "#{provider}-number-ref",
          provider_connection_id: provider_connection.id,
          routing_mode: 'operator'
        }
      )
    end
    let(:contact) { create(:contact, account: account, phone_number: from_number) }
    let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: from_number) }
    let!(:existing_conversation) do
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        identifier: "#{provider}-previous-call",
        additional_attributes: {
          'call_direction' => 'inbound',
          'call_status' => 'completed',
          "#{provider}_call_ref" => "#{provider}-previous-call",
          'agent_id' => 123,
          'call_started_at' => 100,
          'call_ended_at' => 120,
          'call_duration' => 20,
          'recording_ref' => 'old-recording.wav',
          'recording' => { 'storage_key' => 'old-recording.wav' },
          'from_number' => '+15550000000',
          'to_number' => '+15559990000'
        }
      )
    end

    before do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: existing_conversation,
        message_type: :incoming,
        content_type: :voice_call,
        sender: contact,
        source_id: "voice_call:#{provider}-previous-call",
        content_attributes: { 'data' => { 'call_sid' => "#{provider}-previous-call", 'status' => 'completed' } }
      )
    end

    it 'reuses the latest contact conversation and creates a separate bubble for the new call' do
      expect { perform_builder }.not_to(change { account.conversations.where(inbox_id: inbox.id, contact_id: contact.id).count })

      existing_conversation.reload
      voice_messages = existing_conversation.messages.voice_calls.order(:created_at, :id)

      aggregate_failures do
        expect(existing_conversation.identifier).to eq("#{provider}-previous-call")
        expect(existing_conversation).to be_open
        expect(existing_conversation.additional_attributes).to include(
          'call_direction' => 'inbound',
          'call_status' => 'ringing',
          "#{provider}_call_ref" => call_sid,
          'from_number' => from_number,
          'to_number' => channel.phone_number
        )
        expect(existing_conversation.additional_attributes).not_to have_key('agent_id')
        expect(existing_conversation.additional_attributes).not_to have_key('call_started_at')
        expect(existing_conversation.additional_attributes).not_to have_key('call_ended_at')
        expect(existing_conversation.additional_attributes).not_to have_key('call_duration')
        expect(existing_conversation.additional_attributes).not_to have_key('recording_ref')
        expect(existing_conversation.additional_attributes).not_to have_key('recording')
        expect(voice_messages.count).to eq(2)
        expect(voice_messages.last.source_id).to eq("voice_call:#{call_sid}")
        expect(voice_messages.last.content_attributes.dig('data', 'call_sid')).to eq(call_sid)
        expect(voice_messages.first.content_attributes.dig('data', 'call_sid')).to eq("#{provider}-previous-call")
      end
    end
  end
end
