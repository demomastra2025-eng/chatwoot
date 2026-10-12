require 'rails_helper'

RSpec.describe Contacts::ServerOwnedAttributes do
  let(:account) { create(:account) }

  describe '.strip birth date' do
    it 'drops a birth date written as a calendar date that does not exist, and keeps the other attributes' do
      ['2026-02-30', '30.02.1990', '1990-13-40', '1990-02-30T00:00:00.000Z', '1990-02-30 00:00:00', '31.04.1990'].each do |value|
        expect(described_class.strip({ 'birth_date' => value, 'city' => 'Almaty' })).to eq('city' => 'Almaty'), value.inspect
      end
      expect(described_class.strip({ birth_date: '2026-02-30', city: 'Almaty' })).to eq('city' => 'Almaty')
    end

    it 'keeps an existing date, the dotted form the dashboard reads, and an empty value that clears the field' do
      ['1990-03-05', '1990-03-05T00:00:00.000Z', '20.07.1994', '', nil].each do |value|
        expect(described_class.strip({ 'birth_date' => value })).to eq('birth_date' => value), value.inspect
      end
    end

    it 'keeps free text that is not a calendar date, as before' do
      ['5/3/1990', '5 March 1990', '1990-03-05 00:00:00', 'abc', 19_900_501].each do |value|
        expect(described_class.strip({ 'birth_date' => value })).to eq('birth_date' => value), value.inspect
      end
    end

    it 'does not look at other keys that hold the same kind of text' do
      expect(described_class.strip({ 'visit_date' => '2026-02-30' })).to eq('visit_date' => '2026-02-30')
    end
  end

  describe 'untrusted writers' do
    let(:card) { create(:contact, account: account, name: 'Patient', custom_attributes: { 'birth_date' => '1994-07-20' }) }

    it 'leaves the birth date of the card alone when a widget visitor identifies with a non-existent one' do
      ContactIdentifyAction.new(contact: card, params: { custom_attributes: { 'birth_date' => '30.02.1990', 'vip' => true } }).perform

      expect(card.reload.custom_attributes).to eq('birth_date' => '1994-07-20', 'vip' => true)
    end

    it 'stores an existing birth date from the widget as before' do
      ContactIdentifyAction.new(contact: card, params: { custom_attributes: { 'birth_date' => '1990-03-05' } }).perform

      expect(card.reload.custom_attributes['birth_date']).to eq('1990-03-05')
    end

    it 'creates imported contacts without a non-existent birth date' do
      bad = DataImport::ContactManager.new(account).build_contact({ email: 'bad@example.com', birth_date: '30.02.1990', city: 'Almaty' })
      good = DataImport::ContactManager.new(account).build_contact({ email: 'good@example.com', birth_date: '20.07.1994', city: 'Almaty' })

      expect(bad.custom_attributes).to eq('city' => 'Almaty')
      expect(good.custom_attributes).to eq('birth_date' => '20.07.1994', 'city' => 'Almaty')
    end
  end
end
