require 'rails_helper'

RSpec.describe Search::ContactQuery do
  let(:account) { create(:account) }

  def found_names(text, **options)
    described_class.new(text, **options).apply(account.contacts).order(:name, :id).pluck(:name)
  end

  describe 'the long-standing matching, which stays' do
    before do
      create(:contact, account: account, name: 'Harry Potter', email: 'harry@test.com', identifier: 'Potter123', phone_number: '+77011234567')
      create(:contact, account: account, name: 'Hermione Granger', email: 'hermione@test.com')
    end

    it 'finds the text inside the name, e-mail, phone number or identifier, ignoring the case' do
      aggregate_failures do
        ['potter', 'HARRY POTTER', 'harry@test', 'otter123', '+7701123'].each do |text|
          expect(found_names(text)).to eq(['Harry Potter']), "expected #{text.inspect} to find Harry"
        end
      end
    end

    it 'does not leak contacts of another account' do
      create(:contact, account: create(:account), name: 'Harry Potter', email: 'other@test.com')

      expect(found_names('Harry')).to eq(['Harry Potter'])
    end

    it 'treats % and _ as plain characters' do
      create(:contact, account: account, name: '50% off_deal', email: 'deal@test.com')

      expect(found_names('%')).to eq(['50% off_deal'])
      expect(found_names('off_d')).to eq(['50% off_deal'])
      expect(found_names('f_d')).to eq(['50% off_deal'])
      expect(found_names('ffxdeal')).to be_empty
    end

    it 'compares the identifier case-sensitively only when asked to, as the contacts search always did' do
      create(:contact, account: account, name: 'Lowercase', email: 'low@test.com', identifier: 'ext-abc')

      expect(found_names('EXT-ABC')).to eq(['Lowercase'])
      expect(found_names('EXT-ABC', identifier_case_sensitive: true)).to be_empty
      expect(found_names('ext-abc', identifier_case_sensitive: true)).to eq(['Lowercase'])
    end
  end

  describe 'a text of digits that is also a phone number' do
    # Regression of an earlier version: a single numeric token of 4 or more digits searched only the phone number.
    it 'still finds the contacts whose name, e-mail or identifier contain it' do
      create(:contact, account: account, name: 'Кабинет 2024', email: 'k@test.com')
      create(:contact, account: account, name: 'Ренат', email: 'user2024@test.com')
      create(:contact, account: account, name: 'Клиент', identifier: 'iin-2024-77')
      create(:contact, account: account, name: 'Номер', phone_number: '+77020240001')
      create(:contact, account: account, name: 'Нет', phone_number: '+77011234567')

      expect(found_names('2024')).to eq(['Кабинет 2024', 'Клиент', 'Номер', 'Ренат'])
    end

    it 'finds a number typed in any format' do
      create(:contact, account: account, name: 'Асель', phone_number: '+77072817060')
      create(:contact, account: account, name: 'Другой', phone_number: '+77011234567')

      expect(found_names('8 (707) 281-70-60')).to eq(['Асель'])
      expect(found_names("+7\u00A0707\u00A0281\u00A070\u00A060")).to eq(['Асель'])
    end

    it 'does not search the whole table for 1-3 digits typed as a number' do
      create(:contact, account: account, name: 'Асель', phone_number: '+77072817060')
      create(:contact, account: account, name: 'Другой', phone_number: '+77011234567')

      expect(found_names('+7 7')).to be_empty
    end
  end

  describe 'several words' do
    before do
      create(:contact, account: account, name: 'Иван Иванов', email: 'a@test.com')
      create(:contact, account: account, name: 'Иван Петров', email: 'b@test.com')
      create(:contact, account: account, name: 'Анна Сергеевна Орлова', email: 'c@test.com')
    end

    it 'finds the name with the words in any order, next to the phrase search that always worked' do
      aggregate_failures do
        expect(found_names('Иванов Иван')).to eq(['Иван Иванов'])
        expect(found_names('иван иванов')).to eq(['Иван Иванов'])
        expect(found_names('Орлова Сергеевна Анна')).to eq(['Анна Сергеевна Орлова'])
        expect(found_names('иван')).to eq(['Иван Иванов', 'Иван Петров'])
        expect(found_names('Иванов Петров')).to be_empty
      end
    end

    it 'does not require the words to follow each other, and every word has to be there' do
      expect(found_names('Анна Орлова')).to eq(['Анна Сергеевна Орлова'])
      expect(found_names('Анна Петров')).to be_empty
    end

    it 'treats е and ё as one letter in every word' do
      create(:contact, account: account, name: 'Семён Киселёв', email: 'd@test.com')

      expect(found_names('киселев семен')).to eq(['Семён Киселёв'])
    end
  end

  describe 'е and ё' do
    before do
      create(:contact, account: account, name: 'Семён Киселёв', email: 'a@test.com')
      create(:contact, account: account, name: 'Алексей Беляев', email: 'b@test.com')
      create(:contact, account: account, name: 'Елена Фёдорова', email: 'c@test.com')
    end

    it 'finds a name spelled with ё by е and the other way round, also when the name has both letters' do
      aggregate_failures do
        ['Семен Киселев', 'Семён Киселёв', 'семён киселев', 'СЕМЕН КИСЕЛЁВ', 'Семён', 'киселев', 'Семен Киселёв'].each do |text|
          expect(found_names(text)).to eq(['Семён Киселёв']), "expected #{text.inspect} to find Семён Киселёв"
        end
      end
    end

    it 'finds a name spelled with е by ё' do
      expect(found_names('Белёв')).to be_empty
      expect(found_names('Алёксей')).to eq(['Алексей Беляев'])
      expect(found_names('Федорова')).to eq(['Елена Фёдорова'])
      expect(found_names('Ёлена Федорова')).to eq(['Елена Фёдорова'])
    end

    it 'does not take regular expression characters in the text for operators' do
      create(:contact, account: account, name: 'Зелёный (VIP) [1]', email: 'd@test.com')

      expect(found_names('зеленый (vip) [1]')).to eq(['Зелёный (VIP) [1]'])
      expect(found_names('зелен.')).to be_empty
      expect(found_names('(е|а)')).to be_empty
    end
  end

  describe 'text copied from somewhere else' do
    before { create(:contact, account: account, name: 'Иван Иванов', email: 'i@test.com') }

    it 'is found with non-breaking, thin and narrow spaces and invisible marks' do
      aggregate_failures do
        ["Иван\u00A0Иванов", "Иван\u2009Иванов", "Иван\u202FИванов", "\u200EИван Иванов\u200F", "\u202AИван Иванов\u202C"].each do |text|
          expect(found_names(text)).to eq(['Иван Иванов']), "expected #{text.inspect} to find the contact"
        end
      end
    end

    it 'does not fail on a NUL byte or invalid UTF-8' do
      expect(found_names("Иван\u0000")).to eq(['Иван Иванов'])
      expect(found_names("Ива\xFFн")).to eq(['Иван Иванов'])
    end
  end
end
