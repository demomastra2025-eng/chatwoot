require 'rails_helper'

RSpec.describe Contacts::ChannelSyncMergeService do
  let(:channel) { create(:channel_whatsapp_web) }
  let(:source) { create(:contact, account: channel.account, name: 'Saved Manual Alias', identifier: 'whatsapp_web:89001@lid') }
  let(:target) { create(:contact, account: channel.account, name: 'Provider Name', phone_number: '+15550000011') }

  def mark_manual(contact)
    contact.update!(additional_attributes: contact.merge_display_source(
      additional_attributes: contact.additional_attributes,
      key: Contact::PRIMARY_NAME_SOURCE_KEY,
      source: { 'kind' => 'manual' }
    ))
  end

  def select_profile(contact, inbox)
    contact_source = create(:contact_inbox, contact: contact, inbox: inbox)
    create(:contact_channel_profile, contact_inbox: contact_source, display_name: contact.name)
    contact.update!(additional_attributes: contact.merge_display_source(
      additional_attributes: contact.additional_attributes,
      key: Contact::PRIMARY_NAME_SOURCE_KEY,
      source: contact.display_source_for_contact_inbox(contact_source)
    ))
  end

  def merge_with_context
    described_class.new(source_contact: source, target_contact: target, name_source_inbox: channel.inbox) { target.name }.perform
  end

  it 'moves a manual LID name and its source together when the target uses the same automatic inbox', :aggregate_failures do
    create(:contact_inbox, contact: source, inbox: channel.inbox, source_id: '89001@lid')
    mark_manual(source)
    select_profile(target, channel.inbox)

    expect(merge_with_context).to be(true)

    expect(target.reload.name).to eq('Saved Manual Alias')
    expect(target.primary_name_source).to eq('kind' => 'manual')
  end

  it 'keeps the target when both cards have manual names, including identity-looking names', :aggregate_failures do
    target.update!(name: '15550000011')
    mark_manual(source)
    mark_manual(target)

    expect(merge_with_context).to be(true)

    expect(target.reload.name).to eq('15550000011')
    expect(target.primary_name_source).to eq('kind' => 'manual')
  end

  it 'keeps a target preference for another live channel', :aggregate_failures do
    mark_manual(source)
    other_inbox = create(:inbox, account: channel.account)
    select_profile(target, other_inbox)
    selected_source = target.primary_name_source

    expect(merge_with_context).to be(true)

    expect(target.reload.name).to eq('Provider Name')
    expect(target.primary_name_source).to eq(selected_source)
  end

  it 'does not mistake an inferred automatic profile for an explicit user choice', :aggregate_failures do
    mark_manual(source)
    other_inbox = create(:inbox, account: channel.account)
    target_source = create(:contact_inbox, contact: target, inbox: other_inbox)
    create(:contact_channel_profile, contact_inbox: target_source, display_name: target.name)

    expect(merge_with_context).to be(true)

    expect(target.reload.name).to eq('Saved Manual Alias')
    expect(target.primary_name_source).to eq('kind' => 'manual')
  end

  it 'keeps the existing merge contract for a caller without the WhatsApp inbox context', :aggregate_failures do
    mark_manual(source)
    select_profile(target, channel.inbox)
    selected_source = target.primary_name_source

    expect(described_class.new(source_contact: source, target_contact: target) { 'Caller Choice' }.perform).to be(true)

    expect(target.reload.name).to eq('Caller Choice')
    expect(target.primary_name_source).to eq(selected_source)
  end

  ['', 'Manual Target'].each do |target_name|
    it "calls a generic caller's preferred-name callback for its manual target #{target_name.inspect}" do
      target.update!(name: target_name)
      mark_manual(target)
      chooser = -> { 'Caller Choice' }
      expect(chooser).to receive(:call).and_call_original

      expect(described_class.new(source_contact: source, target_contact: target) { chooser.call }.perform).to be(true)
      expect(target.reload.name).to eq('Caller Choice')
    end
  end

  it 'does not enable the WhatsApp name policy for a generic inbox context' do
    target.update!(name: '')
    mark_manual(target)
    generic = create(:inbox, account: channel.account)

    result = described_class.new(source_contact: source, target_contact: target, name_source_inbox: generic) { 'Caller Choice' }.perform

    expect(result).to be(true)
    expect(target.reload.name).to eq('Caller Choice')
  end

  it 'keeps nonmanual merges on the existing preferred-name callback', :aggregate_failures do
    result = described_class.new(source_contact: source, target_contact: target, name_source_inbox: channel.inbox) { 'Provider Choice' }.perform
    expect(result).to be(true)

    expect(target.reload.name).to eq('Provider Choice')
    expect(target.primary_name_source).not_to eq('kind' => 'manual')
  end

  it 'does not move a manual name across account boundaries', :aggregate_failures do
    other = create(:contact, name: 'Other Account')
    mark_manual(source)

    expect(described_class.new(source_contact: source, target_contact: other, name_source_inbox: channel.inbox).perform).to be(false)

    expect(source.reload.name).to eq('Saved Manual Alias')
    expect(other.reload.name).to eq('Other Account')
  end
end
