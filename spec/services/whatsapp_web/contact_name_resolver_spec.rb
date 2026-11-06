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

  [
    ['Alpha', 'Zulu', 'Alpha'],
    ["\uE000", "\u{1F600}", "\u{1F600}"],
    ["\uE000", "\u{10000}", "\u{10000}"],
    ['alpha', 'Alpha', 'Alpha'],
    ['AlphaX', 'Alpha', 'Alpha']
  ].each do |left, right, expected|
    [[left, right], [right, left]].each do |stored, incoming|
      it "uses the JavaScript UTF-16 minimum for equal-dated #{stored.inspect} then #{incoming.inspect}", :aggregate_failures do
        first = stored_name.merge('phonebook_name' => stored)
        second = stored_name.merge('phonebook_name' => incoming)
        payload = { phonebookName: incoming, phonebookNameUpdatedAt: first['phonebook_name_updated_at'] }

        expect(resolve(payload, [first]).phonebook_attributes['phonebook_name']).to eq(expected)
        expect(resolve({}, [first, second]).phonebook_attributes['phonebook_name']).to eq(expected)
      end
    end
  end

  undated_name_orders = [%w[Alpha Zulu], %w[Zulu Alpha]]
  [nil, 'not-a-timestamp'].each do |timestamp|
    undated_name_orders.each do |stored, incoming|
      it "preserves incoming and stored-order precedence without a valid date: #{timestamp.inspect}, #{stored} then #{incoming}",
         :aggregate_failures do
        first = { 'phonebook_name' => stored, 'phonebook_name_updated_at' => timestamp }
        second = { 'phonebook_name' => incoming, 'phonebook_name_updated_at' => timestamp }
        payload = { phonebookName: incoming, phonebookNameUpdatedAt: timestamp }

        expect(resolve(payload, [first]).phonebook_attributes).to eq('phonebook_name' => incoming)
        expect(resolve({}, [first, second]).phonebook_attributes).to eq('phonebook_name' => stored)
      end
    end
  end

  it 'preserves a dated name when the incoming timestamp is malformed' do
    payload = { phonebookName: 'Alpha', phonebookNameUpdatedAt: 'not-a-timestamp' }

    expect(resolve(payload, [stored_name]).phonebook_attributes).to eq(stored_name)
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
