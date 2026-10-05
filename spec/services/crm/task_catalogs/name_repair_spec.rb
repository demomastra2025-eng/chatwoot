require 'rails_helper'

RSpec.describe Crm::TaskCatalogs::NameRepair do
  def provision_legacy(account)
    Crm::TaskCatalogs::Provisioner.new(account: account).perform
    account.crm_task_types.find_each do |task_type|
      legacy_name = Crm::TaskCatalogs::SeedNames::LEGACY_TYPE_NAMES.fetch(task_type.code)
      task_type.update_columns(name: legacy_name) # rubocop:disable Rails/SkipsModelValidations
      task_type.outcomes.each do |outcome|
        outcome.update_columns(name: outcome.code.humanize) # rubocop:disable Rails/SkipsModelValidations
      end
    end
    account.crm_task_statuses.find_each do |status|
      status.update_columns(name: Crm::TaskCatalogs::SeedNames::LEGACY_STATUS_NAMES.fetch(status.code)) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  let(:russian_account) { create(:account, locale: 'ru') }
  let(:kazakh_account) { create(:account, locale: 'kk') }
  let(:english_account) { create(:account, locale: 'en') }

  before do
    [russian_account, kazakh_account, english_account].each { |account| provision_legacy(account) }
  end

  it 'renames the legacy English names into each account language' do
    described_class.new(batch_size: 2).perform

    expect(russian_account.crm_task_types.find_by!(code: 'touch').name).to eq('Напоминание')
    expect(kazakh_account.crm_task_types.find_by!(code: 'touch').name).to eq('Еске салу')
    expect(english_account.crm_task_types.find_by!(code: 'touch').name).to eq('Reminder')
    expect(russian_account.crm_task_statuses.find_by!(code: 'cancelled').name).to eq('Отменено')
    expect(kazakh_account.crm_task_outcomes.where(code: 'no_show').pluck(:name).uniq).to eq(['Келмеді'])
  end

  it 'never leaves the word Touch in any catalog row' do
    described_class.new.perform

    names = [russian_account, kazakh_account, english_account].flat_map do |account|
      account.crm_task_types.pluck(:name) + account.crm_task_outcomes.pluck(:name) + account.crm_task_statuses.pluck(:name)
    end
    expect(names.grep(/touch|касан|жанас/i)).to be_empty
  end

  it 'is idempotent and reports the number of renamed rows' do
    first_run = described_class.new.perform
    second_run = described_class.new.perform

    expect(first_run).to be_positive
    expect(second_run).to eq(0)
  end

  it 'keeps names an admin edited, even when a sibling row is still the default' do
    russian_account.crm_task_types.find_by!(code: 'touch').update!(name: 'Follow-up call')
    russian_account.crm_task_outcomes.joins(:task_type)
                   .find_by!(code: 'no_answer', crm_task_types: { code: 'call' }).update!(name: 'Did not pick up')

    described_class.new.perform

    expect(russian_account.crm_task_types.find_by!(code: 'touch').name).to eq('Follow-up call')
    names = russian_account.crm_task_outcomes.where(code: 'no_answer').pluck(:name)
    expect(names).to include('Did not pick up', 'Нет ответа')
  end

  it 'does not touch custom types or outcomes that reuse an English word' do
    custom_type = create(:crm_task_type, account: russian_account, code: 'visit', name: 'Task')
    custom_outcome = create(:crm_task_outcome, account: russian_account, task_type: custom_type, code: 'completed', name: 'Completed')

    described_class.new.perform

    expect(custom_type.reload.name).to eq('Task')
    expect(custom_outcome.reload.name).to eq('Completed')
  end

  it 'only repairs the given accounts' do
    described_class.new(accounts: Account.where(id: russian_account.id)).perform

    expect(russian_account.crm_task_types.find_by!(code: 'touch').name).to eq('Напоминание')
    expect(kazakh_account.crm_task_types.find_by!(code: 'touch').name).to eq('Touch')
  end

  it 'renames the rows inside short transactions when a lock timeout is given' do
    described_class.new(accounts: Account.where(id: russian_account.id), lock_timeout: '2s').perform

    expect(russian_account.crm_task_types.find_by!(code: 'touch').name).to eq('Напоминание')
  end
end
