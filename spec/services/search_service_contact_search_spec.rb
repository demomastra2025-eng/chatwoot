require 'rails_helper'

# The contacts and conversations of the global search find a phone number typed in any format. Separate from
# search_service_spec.rb, whose examples describe the long-standing behaviour and are not touched.
RSpec.describe SearchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:phone_formats) do
    ['87072817060', '+77072817060', '7 707 281 70 60', '+7 (707) 281-70-60', '707 281 70 60', '8-707-281-70-60', '2817060',
     "+7\u00A0707\u00A0281\u00A070\u00A060", "\u200E+7 707 281 70 60\u200F"]
  end
  let!(:phone_contact) { create(:contact, account: account, name: 'Асель', phone_number: '+77072817060') }
  let!(:phone_conversation) { create(:conversation, contact: phone_contact, inbox: inbox, account: account) }

  before do
    Current.account = account
    create(:inbox_member, user: user, inbox: inbox)
    other_contact = create(:contact, account: account, name: 'Другой', phone_number: '+77011234567')
    create(:conversation, contact: other_contact, inbox: inbox, account: account)
    create(:contact, account: create(:account), name: 'Асель', phone_number: '+77072817060')
  end

  after { Current.account = nil }

  def search(text, type)
    described_class.new(current_user: user, current_account: account, params: { q: text }, search_type: type).perform
  end

  it 'finds the contact by a phone number in any format' do
    aggregate_failures do
      phone_formats.each do |text|
        expect(search(text, 'Contact')[:contacts].map(&:id)).to eq([phone_contact.id]), "expected #{text.inspect} to find the contact"
      end
    end
  end

  it 'finds the conversation of the contact by a phone number in any format' do
    aggregate_failures do
      phone_formats.each do |text|
        expect(search(text, 'Conversation')[:conversations].map(&:id)).to eq([phone_conversation.id]), "expected #{text.inspect} to find it"
      end
    end
  end

  it 'finds both through the global search' do
    result = search('8 707 281 70 60', 'all')

    expect(result[:contacts].map(&:id)).to eq([phone_contact.id])
    expect(result[:conversations].map(&:id)).to eq([phone_conversation.id])
  end

  it 'finds a name with е and ё interchanged, in contacts and in conversations' do
    create(:contact, account: account, name: 'Семён Киселёв', email: 'semen@test.com').tap do |contact|
      create(:conversation, contact: contact, inbox: inbox, account: account)
    end

    result = search('семен киселев', 'all')

    expect(result[:contacts].map(&:name)).to eq(['Семён Киселёв'])
    expect(result[:conversations].map { |conversation| conversation.contact.name }).to eq(['Семён Киселёв'])
  end

  it 'still finds a numeric token of 4 or more digits in the name and the e-mail of a contact' do
    by_name = create(:contact, account: account, name: 'Кабинет 2024', email: 'k@test.com')
    by_email = create(:contact, account: account, name: 'Ренат', email: 'user2024@test.com')

    expect(search('2024', 'Contact')[:contacts].map(&:id)).to contain_exactly(by_name.id, by_email.id)
  end

  it 'does not fail on a NUL byte in the query, in any tab' do
    aggregate_failures do
      %w[all Contact Conversation Message Article].each do |type|
        expect { search("Асель\u0000", type).transform_values(&:to_a) }.not_to raise_error
      end
      expect(search("Асель\u0000", 'Contact')[:contacts].map(&:id)).to eq([phone_contact.id])
    end
  end
end
