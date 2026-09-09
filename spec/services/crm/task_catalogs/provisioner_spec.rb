require 'rails_helper'

RSpec.describe Crm::TaskCatalogs::Provisioner do
  let(:account) { create(:account) }

  before { account.enable_features!('crm_tasks') }

  it 'creates the complete task catalog as one account-scoped invariant' do
    described_class.new(account: account).perform

    expect(account.crm_task_statuses.pluck(:code)).to include(*described_class::TASK_STATUS_DEFINITIONS.pluck(:code))
    expect(account.crm_task_types.pluck(:code)).to include(*described_class::TASK_TYPE_DEFINITIONS.pluck(:code))
    described_class::TASK_OUTCOMES.each do |task_type_code, outcome_codes|
      task_type = account.crm_task_types.find_by!(code: task_type_code)
      expect(task_type.outcomes.pluck(:code)).to include(*outcome_codes)
    end
  end

  it 'takes the account catalog advisory lock before repairing an incomplete catalog' do
    described_class.new(account: account).perform
    account.crm_task_types.find_by!(code: 'call').outcomes.find_by!(code: 'answered').delete
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      statements << sql if sql.include?('pg_advisory_xact_lock') || sql.start_with?('INSERT INTO "crm_task_outcomes"')
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      described_class.new(account: account).perform
    end

    expect(statements.first).to include('pg_advisory_xact_lock')
    expect(statements.last).to start_with('INSERT INTO "crm_task_outcomes"')
    expect(account.crm_task_types.find_by!(code: 'call').outcomes.find_by(code: 'answered')).to be_present
  end

  it 'uses a read-only fast path when the complete catalog already exists' do
    described_class.new(account: account).perform
    mutations = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      mutations << sql if sql.include?('pg_advisory_xact_lock') || sql.match?(/\A(?:INSERT|UPDATE|DELETE) /)
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      described_class.new(account: account).perform
    end

    expect(mutations).to be_empty
  end
end
