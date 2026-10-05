require 'rails_helper'

RSpec.describe Crm::Deals::ContactOwnerSync do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:owner) { create(:user, account: account, role: :agent) }
  let(:new_owner) { create(:user, account: account, role: :agent) }

  def deal_with_contact(contact_owner:, deal_owner:, primary: true)
    contact = create(:contact, account: account, owner: contact_owner)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: deal_owner)
    create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: primary)
    [deal, contact]
  end

  def change_owner_silently(deal, user)
    deal.update_columns(owner_id: user&.id) # rubocop:disable Rails/SkipsModelValidations
    deal
  end

  def count_contact_lookups(&)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      statements << payload[:sql] if payload[:sql].include?('SELECT "crm_deal_contacts"."contact_id"')
    end
    yield
    statements.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it 'gives the primary contact the owner of the deal' do
    deal, contact = deal_with_contact(contact_owner: owner, deal_owner: owner)
    change_owner_silently(deal, new_owner)

    expect(described_class.call([deal])).to eq(1)
    expect(contact.reload.owner).to eq(new_owner)
  end

  it 'leaves the primary contact without owner when the deal has none' do
    deal, contact = deal_with_contact(contact_owner: owner, deal_owner: owner)
    change_owner_silently(deal, nil)

    expect(described_class.call([deal])).to eq(1)
    expect(contact.reload.owner).to be_nil
  end

  it 'does nothing when the deal has no primary contact' do
    deal, contact = deal_with_contact(contact_owner: owner, deal_owner: owner, primary: false)
    change_owner_silently(deal, new_owner)

    expect(described_class.call([deal])).to eq(0)
    expect(contact.reload.owner).to eq(owner)
  end

  it 'does nothing for a deal without any contact' do
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: new_owner)

    expect(described_class.call([deal])).to eq(0)
  end

  it 'does not write a contact that already has the owner' do
    deal, contact = deal_with_contact(contact_owner: new_owner, deal_owner: new_owner)
    updated_at = contact.reload.updated_at

    expect(described_class.call([deal])).to eq(0)
    expect(contact.reload.updated_at).to eq(updated_at)
  end

  it 'ignores deals that are not saved or already destroyed' do
    unsaved = build(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: new_owner)
    destroyed, contact = deal_with_contact(contact_owner: owner, deal_owner: new_owner)
    allow(destroyed).to receive(:destroyed?).and_return(true)

    expect(described_class.call([unsaved, destroyed])).to eq(0)
    expect(contact.reload.owner).to eq(owner)
  end

  it 'never touches a contact of another account' do
    foreign_contact = create(:contact, account: create(:account), owner: nil)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: new_owner)
    build(:crm_deal_contact, account: account, deal: deal, contact: foreign_contact, primary: true).save!(validate: false)

    expect(described_class.call([deal])).to eq(0)
    expect(foreign_contact.reload.owner).to be_nil
  end

  it 'reports a contact that cannot be saved instead of failing the deal write' do
    deal, contact = deal_with_contact(contact_owner: owner, deal_owner: owner)
    change_owner_silently(deal, new_owner)
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
    allow_any_instance_of(Contact).to receive(:update!).and_raise(ActiveRecord::RecordInvalid) # rubocop:disable RSpec/AnyInstance

    expect(described_class.call([deal])).to eq(0)
    expect(tracker).to have_received(:capture_exception)
    expect(contact.reload.owner).to eq(owner)
  end

  context 'when many deals change owner at once' do
    let(:deals_with_contacts) do
      Array.new(4) { deal_with_contact(contact_owner: owner, deal_owner: owner) }
    end

    it 'looks the primary contacts up once per owner, not once per deal' do
      deals = deals_with_contacts.map { |deal, _contact| change_owner_silently(deal, new_owner) }

      lookups = count_contact_lookups { expect(described_class.call(deals)).to eq(4) }

      expect(lookups).to eq(1)
      expect(deals_with_contacts.map { |_deal, contact| contact.reload.owner }).to all(eq(new_owner))
    end

    it 'does one lookup per distinct owner' do
      deals = deals_with_contacts.each_with_index.map do |(deal, _contact), index|
        change_owner_silently(deal, index.even? ? new_owner : nil)
      end

      lookups = count_contact_lookups { described_class.call(deals) }

      expect(lookups).to eq(2)
      expect(deals_with_contacts.map { |_deal, contact| contact.reload.owner }).to eq([new_owner, nil, new_owner, nil])
    end
  end
end
