# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::PasswordRules do
  describe '.problems' do
    it 'is empty for a password that follows every rule' do
      expect(described_class.problems('Sezim-2026x')).to be_empty
      expect(described_class).to be_valid('Aa1!aa')
    end

    it 'names the rules a password breaks, in the order of the list' do
      expect(described_class.problems('abc')).to eq(%i[length uppercase number special])
      expect(described_class.problems('ABCDEF1!')).to eq(%i[lowercase])
      expect(described_class.problems('Abcdef!!')).to eq(%i[number])
      expect(described_class.problems('Abcdef11')).to eq(%i[special])
    end

    it 'names a character that is not allowed at all' do
      expect(described_class.problems('Пароль-2026')).to include(:unknown, :uppercase, :lowercase)
      expect(described_class.problems('Aa1!aa€')).to eq([:unknown])
    end

    it 'counts the length: too short and too long' do
      expect(described_class.problems('Aa1!a')).to eq([:length])
      expect(described_class.problems("Aa1!#{'a' * 130}")).to eq([:length])
    end

    it 'is the same answer as the model gives for the same passwords' do
      ['Aa1!aa', 'abc', 'Sezim-2026x', 'ABCDEF1!', 'Пароль-2026', 'Aa1!a', 'Abcdef11'].each do |password|
        user = User.new(email: 'rules@example.test', name: 'Rules', password: password, password_confirmation: password)
        user.valid?

        expect(described_class.valid?(password)).to eq(user.errors[:password].empty?), "the model and the rules differ for #{password.inspect}"
      end
    end
  end

  describe '.message' do
    it 'is nil for a good password' do
      expect(described_class.message('Sezim-2026x')).to be_nil
    end

    it 'lists what is missing, in Russian' do
      expect(described_class.message('abc')).to eq(
        'Пароль не подходит: он должен содержать не меньше 6 знаков; заглавную латинскую букву; цифру; спецсимвол (например ! @ # $ %).'
      )
    end

    it 'says Russian letters do not fit' do
      expect(described_class.message('Aa1!aaй')).to include('русские буквы не подходят')
    end
  end

  describe '.special_characters' do
    it 'is the list the model accepts' do
      expect(described_class.special_characters).to include('!', '@', '#', '$', '%', '-', '_')
      expect(described_class.special_characters).not_to include('a', '1')
    end
  end
end
