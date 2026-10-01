require 'rails_helper'

# M5 + M6: promotion makes the доп. номер the card's primary and moves the number's chat history in one transaction.
RSpec.describe Contacts::SharedPhonePromotionService do
  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }
  let(:inbox) { shared_phone_cloud_inbox(account) }
  let(:card) { shared_phone_card(account, mother) }
  let(:admin) { create(:user, account: account, name: 'Admin') }
  let!(:chat) { shared_phone_chat(account, mother, inbox, phone.delete('+')) }

  # The promotion with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches).
  before { enable_shared_phone_switches! }

  def fingerprint(previous = mother)
    Contacts::NumberHistoryTransferPreview.new(account: account, phone: phone, card: card.reload, previous_holder: previous).fingerprint
  end

  it '(a) promotes from MedElement and moves the chat history of the number', :aggregate_failures do
    contact_inbox, conversation = chat
    result = described_class.new(card: card, basis: 'medelement').perform

    expect(result).to have_attributes(status: :promoted, moved: { contact_inboxes: 1, conversations: 1, messages: 1 })
    expect(card.reload.phone_number).to eq(phone)
    expect(card.custom_attributes['secondary_phones']).to be_blank
    expect(card.custom_attributes.keys & Contacts::SharedPhone::SHARE_KEYS).to be_empty
    expect([contact_inbox.reload.contact_id, conversation.reload.contact_id]).to all(eq(card.id))
    expect(conversation.messages.activity.last.content).to include('MedElement (automatic)')
    expect(mother.reload.phone_number).to eq('+77000000008')
    expect(described_class.new(card: card.reload, basis: 'medelement').perform.status).to eq(:noop)
  end

  it '(a) leaves everything unchanged when the policy blocks' do
    create(:contact, account: account, phone_number: phone)
    result = described_class.new(card: card, basis: 'medelement').perform

    expect(result).to have_attributes(status: :blocked, reason: :held_by_other)
    expect(card.reload.phone_number).to be_nil
    expect(chat.first.reload.contact_id).to eq(mother.id)
  end

  it '(b) promotes with the confirmed preview and records the administrator', :aggregate_failures do
    result = described_class.new(card: card, basis: 'administrator', actor: admin, expected_fingerprint: fingerprint).perform

    expect(result.status).to eq(:promoted)
    expect(result.entry).to include('basis' => 'administrator', 'actor' => { 'type' => 'User', 'id' => admin.id })
    expect(chat.last.reload.messages.activity.last.content).to include('administrator Admin')
  end

  it '(b) refuses a stale preview and a number someone else took meanwhile', :aggregate_failures do
    expect { described_class.new(card: card, basis: 'administrator', actor: admin, expected_fingerprint: 'stale').perform }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq('SHARED_PHONE_STATE_CHANGED') }

    expected = fingerprint
    create(:contact, account: account, phone_number: phone)
    expect { described_class.new(card: card, basis: 'administrator', actor: admin, expected_fingerprint: expected).perform }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq('SHARED_PHONE_TAKEN') }
    expect(card.reload.phone_number).to be_nil
  end

  it '(b) records a promotion without history when nobody chats from the number' do
    chat.first.update!(source_id: '77000000001')
    result = described_class.new(card: card, basis: 'administrator', actor: admin, expected_fingerprint: fingerprint(nil)).perform

    expect(result.entry).to include('promoted' => true, 'contact_inbox_ids' => [])
    expect(card.reload.phone_number).to eq(phone)
  end
end
