require 'rails_helper'

RSpec.describe Search::PhoneQuery do
  let(:account) { create(:account) }
  let!(:contact) { create(:contact, account: account, name: 'Асель', phone_number: '+77072817060') }
  let(:other_account) { create(:account) }

  before do
    create(:contact, account: account, name: 'Другой', phone_number: '+77011234567')
    create(:contact, account: other_account, name: 'Чужой', phone_number: '+77072817060')
  end

  def found_ids(text)
    query = described_class.parse(text)
    return [] unless query

    account.contacts.where(query.condition).pluck(:id)
  end

  describe '.parse' do
    it 'is nil for text that is not a phone number' do
      aggregate_failures do
        ['', ' ', '+', 'Иван', '12ab34', '707-abc-2817', 'a@b.kz 7072817060', '+7 707 281 70 60 доб 5'].each do |text|
          expect(described_class.parse(text)).to be_nil, "expected #{text.inspect} not to be a phone number"
        end
      end
    end

    it 'is nil below 4 digits, which would match a large part of the table, and above 15 digits' do
      expect(described_class.parse('707')).to be_nil
      expect(described_class.parse('+7 70')).to be_nil
      expect(described_class.parse('7' * 16)).to be_nil
      expect(described_class.parse('7' * 15)).to be_present
      expect(described_class.parse('7071')).to be_present
    end

    it 'reads the digits of any format' do
      aggregate_failures do
        ['87072817060', '8-707-281-70-60', '8 (707) 281.70.60', '８７０７２８１７０６０'].each do |text|
          expect(described_class.parse(text).digits).to eq('87072817060')
        end
      end
    end
  end

  describe 'a number typed in any format' do
    let(:formats) do
      ['87072817060', '+77072817060', '7 707 281 70 60', '+7 (707) 281-70-60', '707 281 70 60', '8-707-281-70-60', '07072817060',
       '+7 707 281 7060', "+7\u00A0707\u00A0281\u00A070\u00A060", "+7\u2009707\u2009281\u2009\u202F70 60", "\u200E+7 707 281 70 60\u200F",
       "\u202A+7 (707) 281-70-60\u202C", '7072817060', '2817060', '707281', '8 707 281 70 60 ']
    end

    it 'finds the contact, and only the contact of this account' do
      aggregate_failures do
        formats.each do |text|
          expect(found_ids(text)).to eq([contact.id]), "expected #{text.inspect} to find the contact"
        end
      end
    end

    it 'does not find a different number' do
      aggregate_failures do
        ['87012345678', '+7 701 234 56 78', '7012345678', '9999', '2817061'].each do |text|
          expect(found_ids(text)).not_to include(contact.id), "expected #{text.inspect} not to find the contact"
        end
      end
    end
  end

  describe 'a number that is still being typed' do
    # Typing every format from its first character: from the 4th digit on every prefix has to find the number, whether it
    # is stored with the +7 country code or with the 8 trunk prefix (older imports). This is the "dead zone" case: 10-11
    # digits typed with a country code before the number is complete. The only exception is a 4-digit start whose 7 / 8 /
    # 0 prefix is spelled differently from the stored one (+7 707 against 8707...): without the prefix it would be 3 digits.
    ['+7 (707) 281-70-60', '8 707 281 70 60', '+77072817060', '87072817060', '7 707 281 70 60', '707 281 70 60', '8-707-281-70-60'].each do |format|
      %w[+77072817060 87072817060].each do |stored|
        it "finds #{stored} while #{format.inspect} is typed" do
          contact.update_column(:phone_number, stored) # rubocop:disable Rails/SkipsModelValidations
          aggregate_failures do
            (1..format.length).each do |length|
              typed = format[0, length]
              digits = described_class.parse(typed)&.digits
              next if digits.nil? || (digits.length < 5 && !stored.delete('+').include?(digits))

              expect(found_ids(typed)).to include(contact.id), "expected #{typed.inspect} to find #{stored}"
            end
          end
        end
      end
    end
  end

  describe 'numbers of other countries' do
    let!(:ukrainian) { create(:contact, account: account, name: 'Оксана', phone_number: '+380501234567') }

    it 'matches by the last 10 digits and as contained digits, like any other number' do
      aggregate_failures do
        ['+38 (050) 123-45-67', '380501234567', '0501234567', '050 123 45 67', '38050123456', '+38 050 12', '501234567'].each do |text|
          expect(found_ids(text)).to eq([ukrainian.id]), "expected #{text.inspect} to find the number"
        end
      end
    end

    it 'finds the same national number under another country code' do
      expect(found_ids('+1 707 281 7060')).to eq([contact.id])
    end
  end

  describe '#condition' do
    it 'is written like the expression indexes of the contacts table' do
      sql = described_class.parse('87072817060').condition.to_sql

      expect(sql).to include("right(regexp_replace(\"contacts\".\"phone_number\", '[^0-9]', '', 'g'), 10) = '7072817060'")
      expect(sql).to include("regexp_replace(\"contacts\".\"phone_number\", '[^0-9]', '', 'g') LIKE '%87072817060%'")
      expect(sql).to include("LIKE '%7072817060%'")
    end

    it 'has no last-10 arm for a fragment shorter than a full number' do
      expect(described_class.parse('281 70 60').condition.to_sql).not_to include('right(')
    end
  end
end
