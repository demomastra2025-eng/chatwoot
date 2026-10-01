require 'rails_helper'

# M7 / round-8 Q6c: channel lookups by phone use the primary number only; a доп. номер never files a chat under a card.
RSpec.describe ContactInboxWithContactBuilder do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }

  def build_family_chat
    described_class.new(inbox: inbox, source_id: 'family-visitor', contact_attributes: { name: 'Mother', phone_number: phone }).perform
  end

  it 'never finds a patient card through its доп. номер' do
    card = shared_phone_card(account, create(:contact, account: account, phone_number: nil), via: 'booking_chat')

    contact_inbox = build_family_chat

    expect(contact_inbox.contact_id).not_to eq(card.id)
    expect(contact_inbox.contact.phone_number).to eq(phone)
    expect(card.reload.phone_number).to be_nil
  end

  it 'still files the chat under the contact that holds the number as primary' do
    holder = create(:contact, account: account, phone_number: phone)
    shared_phone_card(account, holder)

    contact_inbox = build_family_chat

    expect(contact_inbox.contact_id).to eq(holder.id)
  end
end
