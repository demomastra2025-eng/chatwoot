require 'rails_helper'

# M5(a): automatic promotion only when nothing else could still claim the number.
RSpec.describe Contacts::SharedPhonePromotionPolicy do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  # The mother changed her phone field but still chats from the family number.
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }
  let(:inbox) { shared_phone_cloud_inbox(account) }
  let(:card) { shared_phone_card(account, mother) }

  before do
    # The policy with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches).
    enable_shared_phone_switches!
    shared_phone_chat(account, mother, inbox, phone.delete('+'))
  end

  def decision = described_class.auto_decision(card.reload)

  it 'promotes and names the previous holder when the MedElement number is free' do
    expect(decision).to have_attributes(status: :promote, phone: phone, previous_holder: mother)
    expect(described_class.auto_candidate?(card)).to be(true)
  end

  it 'is off by default: db:migrate seeds the switch off and nothing is promoted (M9)', :aggregate_failures do
    InstallationConfig.where(name: Contacts::SharedPhoneSwitches::KEYS).delete_all
    GlobalConfig.clear_cache
    ConfigLoader.new.process # lib/tasks/db_enhancements.rake runs this after every db:migrate (db:chatwoot_prepare on deploy)
    GlobalConfig.clear_cache

    Contacts::SharedPhoneSwitches::KEYS.each { |key| expect(InstallationConfig.find_by(name: key).value).to be(false) }
    expect(Contacts::SharedPhoneSwitches.states.values).to all(be(false))
    expect(decision.reason).to eq(:kill_switch)
    expect(described_class.auto_candidate?(card)).to be(false)
    expect(described_class.auto_decision(card, check_switches: false)).to be_promote
  end

  it 'turns on only by the installation config, never by ENV or an account setting', :aggregate_failures do
    disable_shared_phone_switches!
    with_modified_env(described_class::CONFIG_KEY => 'true', Contacts::SharedPhoneSwitches::HISTORY_TRANSFER => 'true') do
      account.update!(settings: account.settings.to_h.merge('shared_phone_auto_promotion' => true))
      expect(decision.reason).to eq(:kill_switch)
    end

    enable_shared_phone_switches!(Contacts::SharedPhoneSwitches::AUTO_PROMOTION)
    expect(decision.reason).to eq(:history_transfer_disabled)
    enable_shared_phone_switches!(Contacts::SharedPhoneSwitches::HISTORY_TRANSFER)
    expect(decision).to be_promote
  end

  it 'reads an unreadable switch as off' do
    allow(GlobalConfig).to receive(:get_value).and_raise(Redis::CannotConnectError)

    expect(Contacts::SharedPhoneSwitches.states.values).to all(be(false))
  end

  it 'blocks when another contact holds the number as primary' do
    create(:contact, account: account, phone_number: phone)
    expect(decision.reason).to eq(:held_by_other)
  end

  it 'blocks a hidden-number share whose owner has no primary number yet (M5a)' do
    mother.update!(phone_number: nil)
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::SHARED_VIA_KEY => 'booking_chat'))
    expect(decision.reason).to eq(:owner_unresolved)
  end

  it 'A1 promotes when the owner of a visible share gave up its primary number (not a hidden-number share)', :aggregate_failures do
    mother.update!(phone_number: nil)
    expect(decision).to have_attributes(status: :promote, previous_holder: mother)
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::SHARED_VIA_KEY => 'owner_chat_identity'))
    expect(decision).to have_attributes(status: :promote, previous_holder: mother)
  end

  it 'blocks when the share owner no longer exists' do
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::SHARED_OWNER_KEY => 0))
    expect(decision.reason).to eq(:owner_missing)
  end

  it 'blocks when the MedElement number is unknown, absent or different', :aggregate_failures do
    card.update!(custom_attributes: card.custom_attributes.except(Contacts::SharedPhone::MEDELEMENT_PHONE_KEY))
    expect(decision.reason).to eq(:unknown_medelement_phone)
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::MEDELEMENT_PHONE_KEY => ''))
    expect(decision.reason).to eq(:no_medelement_phone)
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::MEDELEMENT_PHONE_KEY => '+77000000007'))
    expect(decision.reason).to eq(:medelement_phone_mismatch)
  end

  it 'blocks siblings and several previous holders so that the administrator chooses', :aggregate_failures do
    shared_phone_card(account, mother, code: 'daughter-1', name: 'Daughter')
    expect(decision.reason).to eq(:siblings)
  end

  it 'blocks several previous holders' do
    shared_phone_chat(account, create(:contact, account: account, name: 'Father'), shared_phone_cloud_inbox(account), phone.delete('+'))
    expect(decision.reason).to eq(:multiple_previous_holders)
  end

  it 'blocks when the previous holder is itself a patient card' do
    mother.update!(custom_attributes: { 'medelement_patient_code' => 'mother-1' })
    expect(decision.reason).to eq(:previous_holder_is_card)
  end

  it 'blocks while the previous holder has a WhatsApp Web LID chat that is not provably tied (design review)' do
    web_inbox = create(:channel_whatsapp_web, account: account).inbox
    shared_phone_chat(account, mother, web_inbox, phone.delete('+'))
    shared_phone_chat(account, mother, web_inbox, '55555@lid')
    expect(decision.reason).to eq(:unproven_lid_chat)
  end

  it 'blocks a number whose transfer to the card an administrator reverted', :aggregate_failures do
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::TRANSFERS_KEY => [
                                                                   { 'id' => 'r-1', 'direction' => 'out', 'phone' => phone, 'basis' => 'revert',
                                                                     'revert_of' => 't-1' }
                                                                 ]))
    expect(decision.reason).to eq(:reverted_transfer)
    expect(described_class.auto_candidate?(card.reload)).to be(false)
  end

  it 'blocks while a MedElement write for the card is in flight' do
    allow(Contacts::PatientIdentityMergeGuard).to receive(:patient_binding_write_in_flight?).and_return(true)
    expect(decision.reason).to eq(:write_in_flight)
  end
end
