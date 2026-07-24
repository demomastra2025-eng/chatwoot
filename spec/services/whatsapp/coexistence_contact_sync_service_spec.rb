require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceContactSyncService do
  let(:channel) do
    create(
      :channel_whatsapp,
      phone_number: '+77010002030',
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => { 'state' => 'requested' }
      }
    )
  end

  it 'upserts an added address-book contact and preserves a later remove state without deleting CRM data' do
    add_value = {
      state_sync: [{
        action: 'add',
        contact: {
          phone_number: '+7 701 111 22 33',
          first_name: 'Aruzhan',
          full_name: 'Aruzhan S.'
        },
        metadata: { timestamp: '1700000000' }
      }]
    }
    described_class.new(channel: channel, value: add_value).perform

    contact_inbox = channel.inbox.contact_inboxes.find_by!(source_id: '77011112233')
    state = contact_inbox.contact.reload.additional_attributes
                         .dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(contact_inbox.contact.name).to eq('Aruzhan S.')
    expect(state).to include('state' => 'active', 'timestamp' => 1_700_000_000)

    remove_value = {
      state_sync: [{
        action: 'remove',
        contact: { phone_number: '77011112233' },
        metadata: { timestamp: '1700000001' }
      }]
    }
    expect do
      described_class.new(channel: channel, value: remove_value).perform
    end.not_to change(Contact, :count)

    removed_state = contact_inbox.contact.reload.additional_attributes
                                 .dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(removed_state).to include('state' => 'removed', 'timestamp' => 1_700_000_001)
    expect(contact_inbox.reload).to be_present

    described_class.new(channel: channel, value: remove_value).perform
    expect(channel.reload.provider_config.dig('coexistence_sync', 'contacts_events_count')).to eq(2)
  end

  it 'normalizes a provider phone variant before removing an existing contact state' do
    contact = create(
      :contact,
      account: channel.account,
      additional_attributes: {
        'whatsapp_business_app_contacts' => {
          channel.inbox.id.to_s => { 'state' => 'active', 'timestamp' => 1_700_000_000 }
        }
      }
    )
    contact_inbox = create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: '5541988887777'
    )
    remove_value = {
      state_sync: [{
        action: 'remove',
        contact: { phone_number: '554188887777' },
        metadata: { timestamp: '1700000001' }
      }]
    }

    described_class.new(channel: channel, value: remove_value).perform

    state = contact.reload.additional_attributes.dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(state).to include('state' => 'removed', 'phone_number' => contact_inbox.source_id, 'timestamp' => 1_700_000_001)
  end

  it 'persists and replays a missing-target remove after a later add creates the contact' do
    remove_value = {
      state_sync: [{
        action: 'remove',
        contact: { phone_number: '77011112233' },
        metadata: { timestamp: '1700000002' }
      }]
    }

    described_class.new(channel: channel, value: remove_value).perform
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'contacts_events_count' => 0,
      'contacts_state' => 'pending_replay',
      'contacts_pending_events_count' => 1
    )
    expect(sync.dig('contacts_pending_events', 0, 'entry')).to include(
      'action' => 'remove',
      'contact' => include('phone_number' => '77011112233')
    )
    expect(Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)).to contain_exactly(
      have_attributes(
        account_id: channel.account_id,
        reason: 'missing_contact_identity',
        phone_identity: '77011112233'
      )
    )
    add_value = {
      state_sync: [{
        action: 'add',
        contact: { phone_number: '77011112233', full_name: 'Aruzhan' },
        metadata: { timestamp: '1700000001' }
      }]
    }
    described_class.new(channel: channel, value: add_value).perform

    contact = channel.inbox.contact_inboxes.find_by!(source_id: '77011112233').contact
    state = contact.reload.additional_attributes.dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(state).to include('state' => 'removed', 'timestamp' => 1_700_000_002)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include('contacts_events_count' => 2, 'contacts_state' => 'active')
    expect(sync).not_to have_key('contacts_pending_events')
    expect(Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)).to be_empty
  end

  it 'persists the canonical phone identity for pending Brazil contact events' do
    old_format = '554188887777'
    described_class.new(
      channel: channel,
      value: {
        state_sync: [{
          action: 'remove',
          contact: { phone_number: old_format },
          metadata: { timestamp: '1700000003' }
        }]
      }
    ).perform

    expect(Whatsapp::CoexistenceContactPendingEvent.find_by!(channel: channel).phone_identity).to eq('5541988887777')
  end

  it 'applies distinct contact transitions with the same provider timestamp exactly once' do
    timestamp = '1700000003'
    add_value = {
      state_sync: [{
        action: 'add',
        contact: { phone_number: '77011112233', full_name: 'Aruzhan' },
        metadata: { timestamp: timestamp }
      }]
    }
    remove_value = {
      state_sync: [{
        action: 'remove',
        contact: { phone_number: '77011112233' },
        metadata: { timestamp: timestamp }
      }]
    }

    described_class.new(channel: channel, value: add_value).perform
    described_class.new(channel: channel, value: add_value).perform
    described_class.new(channel: channel, value: remove_value).perform
    described_class.new(channel: channel, value: add_value).perform

    contact = channel.inbox.contact_inboxes.find_by!(source_id: '77011112233').contact
    state = contact.reload.additional_attributes.dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(state).to include('state' => 'removed', 'timestamp' => timestamp.to_i)
    expect(state['event_key']).to match(/\A[0-9a-f]{64}\z/)
    expect(state['event_keys'].size).to eq(2)
    expect(channel.reload.provider_config.dig('coexistence_sync', 'contacts_events_count')).to eq(2)
  end

  it 'quarantines a malformed missing-timestamp event without mutating contact state' do
    value = {
      state_sync: [{ action: 'add', contact: { phone_number: '77011112234', full_name: 'Dana' } }]
    }

    described_class.new(channel: channel, value: value).perform
    described_class.new(channel: channel, value: value).perform

    expect(channel.inbox.contact_inboxes.find_by(source_id: '77011112234')).to be_nil
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'contacts_events_count' => 0,
      'contacts_state' => 'manual_recovery_required',
      'contacts_last_error' => 'invalid_timestamp',
      'contacts_quarantined_events_count' => 1
    )
    expect(sync['contacts_quarantined_event_keys'].size).to eq(1)
  end

  it 'bounds distinct same-timestamp fingerprints and quarantines overflow events' do
    timestamp = '1700000004'
    entries = Array.new(40) do |index|
      {
        action: 'add',
        contact: { phone_number: '77011112235', full_name: "Contact #{index}" },
        metadata: { timestamp: timestamp }
      }
    end

    described_class.new(channel: channel, value: { state_sync: entries }).perform

    contact = channel.inbox.contact_inboxes.find_by!(source_id: '77011112235').contact
    state = contact.reload.additional_attributes.dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(state['event_keys'].size).to eq(described_class::MAX_EVENT_KEYS_PER_TIMESTAMP)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'contacts_events_count' => described_class::MAX_EVENT_KEYS_PER_TIMESTAMP,
      'contacts_state' => 'manual_recovery_required',
      'contacts_quarantined_events_count' => 8
    )
    expect(sync['contacts_quarantined_event_keys'].size).to eq(8)
  end

  it 'replays a pending marketing preference when contact sync creates the identity' do
    wa_id = '77011112236'
    lifecycle_state = {
      'pending_marketing_preferences' => {
        wa_id => {
          'value' => 'stop',
          'timestamp' => 1_700_000_005,
          'channel_id' => channel.id,
          'event_fingerprints' => ['preference-event']
        }
      }
    }
    channel.update!(provider_config: channel.provider_config.merge('meta_webhook_lifecycle' => lifecycle_state))
    value = {
      state_sync: [{
        action: 'add',
        contact: { phone_number: wa_id, full_name: 'Pending Preference' },
        metadata: { timestamp: '1700000005' }
      }]
    }

    described_class.new(channel: channel, value: value).perform

    contact = channel.inbox.contact_inboxes.find_by!(source_id: wa_id).contact
    expect(contact.reload.additional_attributes['whatsapp_marketing_preference']).to include(
      'value' => 'stop', 'timestamp' => 1_700_000_005
    )
    expect(channel.reload.provider_config.dig('meta_webhook_lifecycle', 'pending_marketing_preferences')).to be_nil
  end

  it 'archives overflow payloads durably and drains every page after contact identities arrive' do
    remove_entries = Array.new(55) do |index|
      {
        action: 'remove',
        contact: { phone_number: (77_011_120_000 + index).to_s },
        metadata: { timestamp: (1_700_001_000 + index).to_s }
      }
    end
    described_class.new(channel: channel, value: { state_sync: remove_entries }).perform

    ledger = Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)
    expect(ledger.count).to eq(55)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'contacts_pending_events_count' => 55,
      'contacts_pending_archive_count' => 5,
      'contacts_state' => 'pending_replay'
    )
    expect(sync['contacts_pending_events'].size).to eq(described_class::MAX_PENDING_CONTACT_EVENTS)
    expect(sync).not_to have_key('contacts_pending_overflow_count')

    add_entries = remove_entries.map do |entry|
      entry.deep_merge(action: 'add', metadata: { timestamp: (entry.dig(:metadata, :timestamp).to_i - 1).to_s })
    end
    perform_enqueued_jobs(only: Whatsapp::CoexistenceContactPendingEventReconciliationJob) do
      described_class.new(channel: channel, value: { state_sync: add_entries }).perform
    end

    expect(ledger.reload).to be_empty
    final_sync = channel.reload.provider_config['coexistence_sync']
    expect(final_sync).to include('contacts_state' => 'active')
    expect(final_sync).not_to have_key('contacts_pending_events')
  end

  it 'does not resurrect a resolved ledger row from a stale worker snapshot' do
    remove_value = {
      state_sync: [{
        action: 'remove',
        contact: { phone_number: '77011112239' },
        metadata: { timestamp: '1700002000' }
      }]
    }
    described_class.new(channel: channel, value: remove_value).perform

    stale_service = described_class.new(channel: channel, value: {})
    stale_service.instance_variable_set(:@quarantined_events, [])
    stale_service.send(:load_pending_events)

    add_value = {
      state_sync: [{
        action: 'add',
        contact: { phone_number: '77011112239', full_name: 'Resolved Contact' },
        metadata: { timestamp: '1700001999' }
      }]
    }
    described_class.new(channel: channel, value: add_value).perform
    expect(Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)).to be_empty

    stale_service.send(:update_sync_activity, [])

    expect(Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)).to be_empty
    expect(channel.reload.provider_config.dig('coexistence_sync', 'contacts_pending_events')).to be_nil
  end

  it 'revalidates a stale new pending event under the channel lock before inserting it' do
    remove_entry = {
      action: 'remove',
      contact: { phone_number: '77011112240' },
      metadata: { timestamp: '1700003000' }
    }
    described_class.new(channel: channel, value: { state_sync: [remove_entry] }).perform

    stale_service = described_class.new(channel: channel, value: { state_sync: [remove_entry] })
    stale_service.instance_variable_set(:@quarantined_events, [])
    stale_service.send(:load_pending_events)
    expect(stale_service.send(:apply_entry, remove_entry)).to be(false)
    expect(stale_service.instance_variable_get(:@new_pending_events)).not_to be_empty

    add_entry = {
      action: 'add',
      contact: { phone_number: '77011112240', full_name: 'Later Contact' },
      metadata: { timestamp: '1700003001' }
    }
    described_class.new(channel: channel, value: { state_sync: [add_entry] }).perform
    expect(Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)).to be_empty

    stale_service.send(:update_sync_activity, [])

    expect(Whatsapp::CoexistenceContactPendingEvent.where(channel: channel)).to be_empty
    contact = channel.account.contacts.find_by(phone_number: '+77011112240')
    state = contact.additional_attributes.dig('whatsapp_business_app_contacts', channel.inbox.id.to_s)
    expect(state).to include('state' => 'active', 'timestamp' => 1_700_003_001)
  end
end
