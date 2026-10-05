require 'rails_helper'

RSpec.describe Crm::TaskCatalogs::SeedNames do
  # The owner rule: the word «Касание» (en "touch", kk «жанасу») never reaches
  # users, including names seeded into the database.
  forbidden_wording = /касан|жанас|\btouch(es|ed|ing)?\b/i
  locales = described_class::SUPPORTED_LOCALES
  frontend_locale_path = ->(locale) { Rails.root.join("app/javascript/dashboard/i18n/locale/#{locale}/crm.json") }
  frontend_tasks = ->(locale) { JSON.parse(File.read(frontend_locale_path.call(locale))).dig('CRM', 'TASKS') }

  let(:type_codes) { Crm::TaskCatalogs::Provisioner::TASK_TYPE_DEFINITIONS.pluck(:code) }
  let(:status_codes) { Crm::TaskCatalogs::Provisioner::TASK_STATUS_DEFINITIONS.pluck(:code) }
  let(:outcome_codes) { Crm::TaskCatalogs::Provisioner::TASK_OUTCOMES.values.flatten.uniq }

  it 'maps account languages to a supported seed language' do
    expect(described_class.locale_for('ru')).to eq('ru')
    expect(described_class.locale_for('kk')).to eq('kk')
    expect(described_class.locale_for('en_US')).to eq('en')
    expect(described_class.locale_for('fr')).to eq('en')
    expect(described_class.locale_for(nil)).to eq('en')
  end

  locales.each do |locale|
    it "has a neutral name for every type, outcome and status in #{locale}" do
      names = type_codes.map { |code| described_class.type_name(code, locale) } +
              outcome_codes.map { |code| described_class.outcome_name(code, locale) } +
              status_codes.map { |code| described_class.status_name(code, locale) }

      expect(names).to all(be_present)
      expect(names).not_to include(a_string_matching(/translation missing/i))
      expect(names.grep(forbidden_wording)).to be_empty
    end

    it "uses the same wording as the dashboard in #{locale}" do
      tasks = frontend_tasks.call(locale)

      expect(type_codes.index_with { |code| described_class.type_name(code, locale) })
        .to eq(tasks['ACTIVITY_TYPE'].slice(*type_codes))
      expect(outcome_codes.index_with { |code| described_class.outcome_name(code, locale) })
        .to eq(tasks['OUTCOME'].slice(*outcome_codes))
      expect(status_codes.index_with { |code| described_class.status_name(code, locale) })
        .to eq(tasks['STATUS_NAMES'].slice(*status_codes))
    end
  end

  it 'names the reminder type as the owner asked' do
    expect(described_class.type_name('touch', 'ru')).to eq('Напоминание')
    expect(described_class.type_name('touch', 'en')).to eq('Reminder')
    expect(described_class.type_name('touch', 'kk')).to eq('Еске салу')
  end

  it 'renames the legacy English touch type in every language' do
    locales.each do |locale|
      rename = described_class.renames(locale).find { |entry| entry[:kind] == :type && entry[:code] == 'touch' }

      expect(rename).to include(from: 'Touch', to: described_class.type_name('touch', locale))
    end
  end
end
