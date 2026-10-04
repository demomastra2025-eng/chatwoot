require 'rails_helper'

RSpec.describe Crm::Tasks::CatalogSnapshot do
  let(:account) { create(:account) }

  before do
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'resolves legacy task catalogs once for a collection without per-task catalog queries' do
    task_type = account.crm_task_types.find_by!(code: 'call')
    task_outcome = task_type.outcomes.find_by!(code: 'answered')
    tasks = Array.new(3) do |index|
      task = create(
        :crm_task,
        account: account,
        activity_type: 'call',
        outcome: 'answered',
        title: "Legacy call #{index}"
      )
      # rubocop:disable Rails/SkipsModelValidations -- Simulates mixed-version rows against the expand schema.
      task.update_columns(task_type_id: nil, task_outcome_id: nil, context_kind: nil)
      # rubocop:enable Rails/SkipsModelValidations
      task.reload
    end
    snapshot = described_class.new(account: account)
    catalog_queries = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      catalog_queries << sql if sql.match?(/FROM "crm_task_(types|outcomes)"/)
    end

    payloads = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      tasks.map { |task| Crm::PayloadBuilder.task(task, catalog_snapshot: snapshot) }
    end

    expect(catalog_queries).to be_empty
    expect(payloads).to all(include(
                              context_kind: 'personal',
                              task_type_id: task_type.id,
                              task_outcome_id: task_outcome.id,
                              outcome: 'answered'
                            ))
  end
end
