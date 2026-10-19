# frozen_string_literal: true

require 'rails_helper'

# Russian picks the form of a counted text by the plural category of the number (config/locales/pluralization.ru.rb,
# config/initializers/i18n_pluralization.rb); the other languages keep the one / other choice.
RSpec.describe 'I18n plural forms' do
  def accounts_total(count, locale: :ru)
    I18n.t('super_admin.organizations.card.accounts.total', count: count, locale: locale)
  end

  describe 'Russian' do
    it 'takes the form of the noun from the number' do
      expect({ 1 => 1, 2 => 2, 5 => 5, 21 => 21, 30 => 30, 111 => 111 }.transform_values { |count| accounts_total(count) }).to eq(
        1 => '1 аккаунт', 2 => '2 аккаунта', 5 => '5 аккаунтов', 21 => '21 аккаунт', 30 => '30 аккаунтов', 111 => '111 аккаунтов'
      )
    end

    it 'puts the numbers that end in 11-14 and the zero into the genitive plural' do
      expect([0, 11, 12, 13, 14, 112, 214].map { |count| accounts_total(count) }).to eq(
        ['0 аккаунтов', '11 аккаунтов', '12 аккаунтов', '13 аккаунтов', '14 аккаунтов', '112 аккаунтов', '214 аккаунтов']
      )
    end

    it 'puts the numbers that end in 2-4 into the genitive singular, but not the ones that end in 12-14' do
      expect([3, 4, 22, 24, 102, 1004].map { |count| accounts_total(count) }).to eq(
        ['3 аккаунта', '4 аккаунта', '22 аккаунта', '24 аккаунта', '102 аккаунта', '1004 аккаунта']
      )
    end

    it 'reads a whole number written as a float and calls a fraction «other»' do
      expect(accounts_total(2.0)).to eq('2 аккаунта')
      expect(accounts_total(1.5)).to eq('1.5 аккаунта')
    end

    it 'does not read a number that was formatted for the page as a count' do
      expect(accounts_total('1 234')).to eq('1 234 аккаунта')
    end

    # Every counted text of the Russian locales has the forms any whole number may ask for: the category of the number or
    # «other» (the lookup raises otherwise)
    it 'has a form for every number in every counted text' do
      plural_keys = %i[zero one two few many other]
      rule = I18n.t('i18n.plural.rule', locale: :ru, resolve: false)
      incomplete = []
      walk = lambda do |tree, path|
        tree.each do |key, value|
          next unless value.is_a?(Hash)

          if value.keys.any?(plural_keys) && value.keys.all?(plural_keys)
            missing = (0..1200).reject { |n| value.key?(:other) || value.key?(rule.call(n)) }
            incomplete << "#{(path + [key]).join('.')} (#{missing.first(3).join(', ')})" if missing.any?
          else
            walk.call(value, path + [key])
          end
        end
      end
      walk.call(I18n.backend.send(:translations)[:ru], [])

      expect(incomplete).to be_empty
    end
  end

  describe 'the other languages' do
    it 'keep the one / other choice' do
      expect(I18n.t('time_units.days', count: 1, locale: :en)).to eq('1 day')
      expect(I18n.t('time_units.days', count: 2, locale: :en)).to eq('2 days')
      expect(I18n.t('time_units.days', count: 21, locale: :en)).to eq('21 days')
    end

    it 'do not borrow the rule of the Russian locale' do
      expect(I18n.t('time_units.hours', count: 22, locale: :en)).to eq('22 hours')
      expect(I18n.t('time_units.hours', count: 1, locale: :en)).to eq('1 hour')
    end
  end
end
