require 'rails_helper'

RSpec.describe Whatsapp::MarketingPreferenceService do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:lifecycle_state) { {} }
  let(:service) { described_class.new(channel: channel, lifecycle_state: lifecycle_state) }
  let(:wa_id) { '16505551234' }
  let(:contact) { create(:contact, account: channel.account) }
  let!(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: wa_id) }

  def preference(value:, timestamp:, contact_id: wa_id)
    {
      wa_id: contact_id,
      category: 'marketing_messages',
      value: value,
      timestamp: timestamp
    }
  end

  it 'ignores older events and accepts newer events' do
    expect(service.apply(preference(value: 'stop', timestamp: 20))).to eq(:applied)
    expect(service.apply(preference(value: 'resume', timestamp: 10))).to eq(:duplicate)
    expect(contact.reload.additional_attributes.dig('whatsapp_marketing_preference', 'value')).to eq('stop')

    expect(service.apply(preference(value: 'resume', timestamp: 30))).to eq(:applied)
    expect(contact.reload.additional_attributes['whatsapp_marketing_preference']).to include(
      'value' => 'resume', 'timestamp' => 30, 'channel_id' => channel.id
    )
  end

  it 'accepts distinct same-timestamp changes but ignores a replay of an earlier event' do
    expect(service.apply(preference(value: 'stop', timestamp: 20))).to eq(:applied)
    expect(service.apply(preference(value: 'resume', timestamp: 20))).to eq(:applied)
    expect(service.apply(preference(value: 'stop', timestamp: 20))).to eq(:duplicate)

    stored = contact.reload.additional_attributes['whatsapp_marketing_preference']
    expect(stored).to include('value' => 'resume', 'timestamp' => 20)
    expect(stored['event_fingerprints'].size).to eq(2)
  end

  it 'records malformed timestamps as an explicit durable ignore' do
    expect(service.apply(preference(value: 'stop', timestamp: 'invalid'))).to eq(:invalid)

    expect(lifecycle_state['invalid_marketing_preferences_count']).to eq(1)
    expect(contact.reload.additional_attributes).not_to include('whatsapp_marketing_preference')
  end

  it 'keeps an unknown contact preference pending and replays it after identity creation' do
    contact_inbox.destroy!

    expect(service.apply(preference(value: 'stop', timestamp: 20))).to eq(:pending)
    expect(lifecycle_state.dig('pending_marketing_preferences', wa_id)).to include(
      'value' => 'stop', 'timestamp' => 20
    )

    replacement_contact = create(:contact, account: channel.account)
    replacement_inbox = create(:contact_inbox, inbox: channel.inbox, contact: replacement_contact, source_id: wa_id)

    expect(service.replay_for(replacement_inbox)).to eq(:applied)
    expect(replacement_contact.reload.additional_attributes['whatsapp_marketing_preference']).to include(
      'value' => 'stop', 'timestamp' => 20
    )
    expect(lifecycle_state).not_to include('pending_marketing_preferences')
  end
end
