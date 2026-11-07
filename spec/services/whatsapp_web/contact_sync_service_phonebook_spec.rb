require 'rails_helper'

RSpec.describe WhatsappWeb::ContactSyncService do
  let(:channel) { create(:channel_whatsapp_web) }
  let(:jid) { '15550000011@s.whatsapp.net' }
  let(:saved_at) { '2026-11-01T12:00:00.000Z' }

  before do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)
  end

  def sync(payload = {}, current_channel = channel)
    described_class.new(channel: current_channel, contact_payload: { remoteJid: jid, pushName: 'Profile Name' }.merge(payload)).perform
  end

  def sync_saved_name
    sync(phonebookName: 'Saved Alias', phonebookNameUpdatedAt: saved_at)
  end

  it 'keeps the saved name for the card and channel profile after later incoming/profile and avatar-only events', :aggregate_failures do
    source = sync_saved_name
    sync(pushName: 'Changed Profile')
    sync(pushName: nil, profilePicUrl: 'https://cdn.example.com/avatar.jpg')

    expect(source.contact.reload.name).to eq('Saved Alias')
    expect(source.reload.channel_profile.display_name).to eq('Saved Alias')
    expect(source.channel_profile.profile_data).to include('phonebook_name' => 'Saved Alias', 'phonebook_name_updated_at' => saved_at)
    expect(source.channel_profile.profile_data['last_provider_display_name']).to eq('Changed Profile')
  end

  it 'updates the saved name without allowing an older subsequent snapshot to restore it', :aggregate_failures do
    source = sync_saved_name
    sync(phonebookName: 'New Alias', phonebookNameUpdatedAt: '2026-11-02T12:00:00Z')
    sync(phonebookName: 'Old Alias', phonebookNameUpdatedAt: '2026-10-31T12:00:00Z')

    expect(source.contact.reload.name).to eq('New Alias')
    expect(source.reload.channel_profile.display_name).to eq('New Alias')
  end

  undated_name_orders = [%w[Alpha Zulu], %w[Zulu Alpha]]
  [nil, 'not-a-timestamp'].each do |timestamp|
    undated_name_orders.each do |first, second|
      it "accepts an undated phonebook rename #{first} to #{second} with timestamp #{timestamp.inspect}", :aggregate_failures do
        source = sync(phonebookName: first, phonebookNameUpdatedAt: timestamp)
        sync(phonebookName: second, phonebookNameUpdatedAt: timestamp)

        expect(source.contact.reload.name).to eq(second)
        expect(source.reload.channel_profile.display_name).to eq(second)
        expect(source.channel_profile.profile_data['phonebook_name']).to eq(second)
        expect(source.channel_profile.profile_data).not_to have_key('phonebook_name_updated_at')
      end
    end
  end

  [
    ['Alpha', 'Zulu', 'Alpha'],
    ["\uE000", "\u{1F600}", "\u{1F600}"],
    ["\uE000", "\u{10000}", "\u{10000}"],
    ['alpha', 'Alpha', 'Alpha'],
    ['AlphaX', 'Alpha', 'Alpha']
  ].each do |left, right, expected|
    [[left, right], [right, left]].each do |first, second|
      it "converges after equal-dated webhooks #{first.inspect} then #{second.inspect}", :aggregate_failures do
        source = sync(phonebookName: first, phonebookNameUpdatedAt: saved_at)
        sync(phonebookName: second, phonebookNameUpdatedAt: saved_at)

        expect(source.contact.reload.name).to eq(expected)
        expect(source.reload.channel_profile.display_name).to eq(expected)
        expect(source.channel_profile.profile_data).to include('phonebook_name' => expected, 'phonebook_name_updated_at' => saved_at)
      end
    end
  end

  equal_date_names = ["\u{1F600}", "\uE000"]
  ['Manual Alias', '15550000011'].each do |manual_name|
    it "preserves manual #{manual_name.inspect} while equal-dated phonebook events converge", :aggregate_failures do
      source = sync(phonebookName: "\uE000", phonebookNameUpdatedAt: saved_at)
      source.contact.update!(
        name: manual_name,
        additional_attributes: source.contact.merge_display_source(
          additional_attributes: source.contact.additional_attributes,
          key: Contact::PRIMARY_NAME_SOURCE_KEY,
          source: { 'kind' => Contact::DISPLAY_SOURCE_KIND_MANUAL }
        )
      )
      equal_date_names.each { |name| sync(phonebookName: name, phonebookNameUpdatedAt: saved_at) }

      expect(source.contact.reload.name).to eq(manual_name)
      expect(source.contact.primary_name_source).to eq('kind' => 'manual')
      expect(source.reload.channel_profile.display_name).to eq("\u{1F600}")
    end
  end

  it 'preserves another selected channel while equal-dated phonebook events converge', :aggregate_failures do
    source = sync(phonebookName: 'Zulu', phonebookNameUpdatedAt: saved_at)
    telegram = create(:channel_telegram_personal, account: channel.account)
    other_source = create(:contact_inbox, contact: source.contact, inbox: telegram.inbox, source_id: '89001')
    create(:contact_channel_profile, contact_inbox: other_source, display_name: '15550000011', provider: 'telegram_personal')
    selected_source = source.contact.display_source_for_contact_inbox(other_source)
    source.contact.update!(
      name: '15550000011',
      additional_attributes: source.contact.merge_display_source(
        additional_attributes: source.contact.additional_attributes,
        key: Contact::PRIMARY_NAME_SOURCE_KEY,
        source: selected_source
      )
    )
    %w[Alpha Zulu].each { |name| sync(phonebookName: name, phonebookNameUpdatedAt: saved_at) }

    expect(source.contact.reload.name).to eq('15550000011')
    expect(source.contact.primary_name_source).to eq(selected_source)
    expect(source.reload.channel_profile.display_name).to eq('Alpha')
  end

  it 'preserves ordinary and technical manual card names while retaining automatic profile provenance', :aggregate_failures do
    source = sync_saved_name
    ['Manual Alias', '15550000011'].each do |manual_name|
      source.contact.update!(
        name: manual_name,
        additional_attributes: source.contact.merge_display_source(
          additional_attributes: source.contact.additional_attributes,
          key: Contact::PRIMARY_NAME_SOURCE_KEY,
          source: { 'kind' => Contact::DISPLAY_SOURCE_KIND_MANUAL }
        )
      )
      sync(phonebookName: 'Updated Saved Alias', phonebookNameUpdatedAt: '2026-11-03T12:00:00Z')

      expect(source.contact.reload.name).to eq(manual_name)
      expect(source.reload.channel_profile.display_name).to eq('Updated Saved Alias')
    end
  end

  it 'keeps an explicitly selected other channel name even when it resembles an identity', :aggregate_failures do
    source = sync_saved_name
    telegram = create(:channel_telegram_personal, account: channel.account)
    telegram_source = create(:contact_inbox, contact: source.contact, inbox: telegram.inbox, source_id: '89001')
    create(:contact_channel_profile, contact_inbox: telegram_source, display_name: '15550000011', provider: 'telegram_personal')
    source.contact.update!(
      name: '15550000011',
      additional_attributes: source.contact.merge_display_source(
        additional_attributes: source.contact.additional_attributes,
        key: Contact::PRIMARY_NAME_SOURCE_KEY,
        source: source.contact.display_source_for_contact_inbox(telegram_source)
      )
    )

    sync(pushName: 'Another Profile')

    expect(source.contact.reload.name).to eq('15550000011')
    expect(source.contact.primary_name_source['contact_inbox_id']).to eq(telegram_source.id)
  end

  it 'retains saved-name provenance when a LID identity is resolved to its phone JID', :aggregate_failures do
    lid_source = sync(remoteJid: '89001@lid', phonebookName: 'Saved Alias', phonebookNameUpdatedAt: saved_at)
    resolved_source = sync(remoteLid: '89001@lid', pushName: 'Profile After Resolution')

    expect(resolved_source.contact.reload.name).to eq('Saved Alias')
    expect(resolved_source.reload.channel_profile.profile_data['phonebook_name']).to eq('Saved Alias')
    expect(lid_source.reload.contact_id).to eq(resolved_source.contact_id)
  end

  it 'never borrows a saved name from the same remote identity in another account' do
    sync_saved_name
    other_channel = create(:channel_whatsapp_web)

    other_source = sync({ pushName: 'Other Account Profile' }, other_channel)

    expect(other_source.contact.name).to eq('Other Account Profile')
    expect(other_source.channel_profile.profile_data).not_to have_key('phonebook_name')
  end

  it 'does not turn a legacy name into a phonebook source' do
    source = sync(pushName: nil, name: 'Legacy Provider Name')

    expect(source.contact.name).to eq('Legacy Provider Name')
    expect(source.channel_profile.profile_data).not_to have_key('phonebook_name')
  end

  it 'does not claim ownership of a reused meaningful contact when the legacy profile name happens to match', :aggregate_failures do
    contact = create(:contact, account: channel.account, name: 'Profile Name', phone_number: '+15550000011')
    sync
    expect(contact.reload.primary_name_source).to be_blank

    sync_saved_name

    expect(contact.reload.name).to eq('Profile Name')
    expect(contact.primary_name_source).to be_blank
  end

  it 'records the provider creator explicitly and accepts its later phonebook name', :aggregate_failures do
    source = sync
    expect(source.contact.primary_name_source).to include('kind' => 'channel_profile', 'inbox_id' => channel.inbox.id)

    sync_saved_name

    expect(source.contact.reload.name).to eq('Saved Alias')
    expect(source.contact.primary_name_source).to include('kind' => 'channel_profile', 'inbox_id' => channel.inbox.id)
  end

  it 'does not replace a group subject with a personal saved-name field' do
    allow(channel).to receive(:sync_groups?).and_return(true)
    source = sync(remoteJid: '12000000001@g.us', pushName: nil, name: 'Workshop Group', phonebookName: 'Personal Alias')

    expect(source.contact.name).to eq('Workshop Group')
    expect(source.channel_profile.profile_data).not_to have_key('phonebook_name')
  end
end
