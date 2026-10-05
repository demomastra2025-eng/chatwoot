require 'rails_helper'

RSpec.describe Crm::TaskCatalogs::Provisioner do
  forbidden_wording = /касан|жанас|\btouch(es|ed|ing)?\b/i

  def catalog_names(account)
    account.crm_task_types.pluck(:name) +
      account.crm_task_outcomes.pluck(:name) +
      account.crm_task_statuses.pluck(:name)
  end

  def legacy_names!(account)
    account.crm_task_types.find_by!(code: 'touch').update_columns(name: 'Touch') # rubocop:disable Rails/SkipsModelValidations
    account.crm_task_types.find_by!(code: 'call').update_columns(name: 'Call') # rubocop:disable Rails/SkipsModelValidations
    account.crm_task_statuses.find_by!(code: 'todo').update_columns(name: 'To do') # rubocop:disable Rails/SkipsModelValidations
    account.crm_task_outcomes.where(code: 'no_answer').update_all(name: 'No answer') # rubocop:disable Rails/SkipsModelValidations
  end

  %w[ru en kk].each do |locale|
    context "when the account language is #{locale}" do
      let(:account) { create(:account, locale: locale) }

      it 'seeds neutral names in the account language and never the word Touch' do
        described_class.new(account: account).perform

        expect(account.crm_task_types.find_by!(code: 'touch').name)
          .to eq(Crm::TaskCatalogs::SeedNames.type_name('touch', locale))
        expect(account.crm_task_outcomes.joins(:task_type).find_by!(code: 'no_answer', crm_task_types: { code: 'call' }).name)
          .to eq(Crm::TaskCatalogs::SeedNames.outcome_name('no_answer', locale))
        expect(account.crm_task_statuses.find_by!(code: 'todo').name)
          .to eq(Crm::TaskCatalogs::SeedNames.status_name('todo', locale))
        expect(catalog_names(account).grep(forbidden_wording)).to be_empty
      end
    end
  end

  it 'seeds English names for languages without a translation' do
    account = create(:account, locale: 'fr')

    described_class.new(account: account).perform

    expect(account.crm_task_types.find_by!(code: 'touch').name).to eq('Reminder')
  end

  it 'is idempotent' do
    account = create(:account, locale: 'ru')
    described_class.new(account: account).perform

    expect { described_class.new(account: account).perform }
      .not_to(change { [account.crm_task_types.count, account.crm_task_outcomes.count, account.crm_task_statuses.count] })
  end

  describe 'rows created by the first release' do
    let(:account) { create(:account, locale: 'ru') }

    before do
      described_class.new(account: account).perform
      legacy_names!(account)
    end

    it 'renames the unedited English defaults of system codes' do
      described_class.new(account: account).perform

      expect(account.crm_task_types.find_by!(code: 'touch').name).to eq('Напоминание')
      expect(account.crm_task_types.find_by!(code: 'call').name).to eq('Звонок')
      expect(account.crm_task_statuses.find_by!(code: 'todo').name).to eq('К выполнению')
      expect(account.crm_task_outcomes.where(code: 'no_answer').pluck(:name).uniq).to eq(['Нет ответа'])
      expect(catalog_names(account).grep(forbidden_wording)).to be_empty
    end

    it 'keeps names that an admin edited' do
      account.crm_task_types.find_by!(code: 'touch').update!(name: 'Follow-up call')
      account.crm_task_types.find_by!(code: 'meeting').update!(name: 'Visit')

      described_class.new(account: account).perform

      expect(account.crm_task_types.find_by!(code: 'touch').name).to eq('Follow-up call')
      expect(account.crm_task_types.find_by!(code: 'meeting').name).to eq('Visit')
      expect(account.crm_task_types.find_by!(code: 'call').name).to eq('Звонок')
    end
  end

  # Migration 20261004120250 seeds the task catalogs with the bare system code as the name.
  describe 'rows named by their bare system code' do
    let(:account) { create(:account, locale: 'ru') }

    def outcome_of(type_code, code)
      account.crm_task_outcomes.joins(:task_type).find_by!(code: code, crm_task_types: { code: type_code })
    end

    before { described_class.new(account: account).perform }

    it 'renames a type, an outcome and a status that still carry their code' do
      account.crm_task_types.find_by!(code: 'touch').update_columns(name: 'touch') # rubocop:disable Rails/SkipsModelValidations
      outcome_of('call', 'no_answer').update_columns(name: 'no_answer') # rubocop:disable Rails/SkipsModelValidations
      account.crm_task_statuses.find_by!(code: 'todo').update_columns(name: 'todo') # rubocop:disable Rails/SkipsModelValidations

      described_class.new(account: account).perform

      expect(account.crm_task_types.find_by!(code: 'touch').name).to eq('Напоминание')
      expect(outcome_of('call', 'no_answer').name).to eq('Нет ответа')
      expect(account.crm_task_statuses.find_by!(code: 'todo').name).to eq('К выполнению')
      expect(catalog_names(account).grep(forbidden_wording)).to be_empty
    end

    it 'renames only the rows named by their code and keeps edited and neutral names' do
      outcome_of('call', 'no_answer').update_columns(name: 'no_answer') # rubocop:disable Rails/SkipsModelValidations
      outcome_of('touch', 'no_answer').update!(name: 'Did not pick up')

      described_class.new(account: account).perform

      expect(outcome_of('call', 'no_answer').name).to eq('Нет ответа')
      expect(outcome_of('touch', 'no_answer').name).to eq('Did not pick up')
      expect(account.crm_task_types.find_by!(code: 'call').name).to eq('Звонок')
    end

    it 'renames a code that equals the English default of an English account' do
      english_account = create(:account, locale: 'en')
      described_class.new(account: english_account).perform
      english_account.crm_task_types.find_by!(code: 'touch').update_columns(name: 'touch') # rubocop:disable Rails/SkipsModelValidations
      english_account.crm_task_types.find_by!(code: 'task').update_columns(name: 'task') # rubocop:disable Rails/SkipsModelValidations

      described_class.new(account: english_account).perform

      expect(english_account.crm_task_types.find_by!(code: 'touch').name).to eq('Reminder')
      expect(english_account.crm_task_types.find_by!(code: 'task').name).to eq('Task')
    end

    it 'is idempotent after the repair' do
      account.crm_task_types.find_by!(code: 'meeting').update_columns(name: 'meeting') # rubocop:disable Rails/SkipsModelValidations
      described_class.new(account: account).perform

      expect { described_class.new(account: account).perform }
        .not_to(change { account.crm_task_types.order(:id).pluck(:name, :updated_at) })
    end
  end
end
