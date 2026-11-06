require 'rails_helper'

RSpec.describe WhatsappWeb::ContactNameResolver do
  def resolve(payload, stored = [], group: false)
    described_class.new(payload: payload, stored_profiles: stored, group: group)
  end

  let(:stored_name) { { 'phonebook_name' => 'Saved Alias', 'phonebook_name_updated_at' => '2026-11-01T12:00:00.000Z' } }

  it 'uses an explicitly sourced phonebook name ahead of the profile name' do
    result = resolve({ phonebookName: 'Saved Alias', phonebookNameUpdatedAt: '2026-11-01T12:00:00Z', pushName: 'Profile Name' })

    expect(result.display_name(provider_name: 'Profile Name', identity_name: '15550000001')).to eq('Saved Alias')
  end

  it 'preserves a dated saved name when partial updates omit or empty its fields' do
    [{ pushName: 'New Profile' }, { phonebookName: nil }, { phonebookName: ' ' }].each do |payload|
      expect(resolve(payload, [stored_name]).phonebook_attributes).to include('phonebook_name' => 'Saved Alias')
    end
  end

  it 'does not replace a saved name with an older or undated provider snapshot' do
    [{ phonebookName: 'Old Alias', phonebookNameUpdatedAt: '2026-10-31T12:00:00Z' }, { phonebookName: 'Undated Alias' }].each do |payload|
      expect(resolve(payload, [stored_name]).phonebook_attributes).to include('phonebook_name' => 'Saved Alias')
    end
  end

  it 'accepts a newer saved name and stores its timestamp' do
    result = resolve({ phonebookName: 'New Alias', phonebookNameUpdatedAt: '2026-11-02T12:00:00Z' }, [stored_name])

    expect(result.phonebook_attributes).to eq('phonebook_name' => 'New Alias', 'phonebook_name_updated_at' => '2026-11-02T12:00:00.000Z')
  end

  it 'selects the newest known saved name when proven identity profiles are joined' do
    newer = stored_name.merge('phonebook_name' => 'Latest Alias', 'phonebook_name_updated_at' => '2026-11-03T12:00:00Z')

    expect(resolve({}, [newer, stored_name]).phonebook_attributes['phonebook_name']).to eq('Latest Alias')
  end

  it 'does not infer phonebook provenance from legacy name or pushName fields' do
    result = resolve({ name: 'Legacy Name', pushName: 'Profile Name' })

    expect(result.phonebook_attributes).to eq({})
    expect(result.display_name(provider_name: 'Profile Name', identity_name: '15550000001')).to eq('Profile Name')
  end

  it 'leaves group names to their existing subject resolver' do
    result = resolve({ phonebookName: 'Personal Alias' }, [stored_name], group: true)

    expect(result.phonebook_attributes).to eq({})
    expect(result.display_name(provider_name: 'Workshop Group', identity_name: '120000@g.us')).to eq('Workshop Group')
  end
end
