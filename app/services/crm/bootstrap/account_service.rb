class Crm::Bootstrap::AccountService
  DEFAULT_PIPELINE_NAME = 'Sales Pipeline'.freeze
  DEFAULT_STAGE_DEFINITIONS = [
    { code: 'new', name: 'New', outcome: 'open' },
    { code: 'qualified', name: 'Qualified', outcome: 'open' },
    { code: 'proposal', name: 'Proposal', outcome: 'open' },
    { code: 'won', name: 'Won', outcome: 'won' },
    { code: 'lost', name: 'Lost', outcome: 'lost' }
  ].freeze
  DEFAULT_TASK_STATUS_DEFINITIONS = [
    { code: 'todo', name: 'To do', category: 'open', default: true },
    { code: 'in_progress', name: 'In progress', category: 'open', default: false },
    { code: 'done', name: 'Done', category: 'done', default: false }
  ].freeze

  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def perform
    ApplicationRecord.transaction do
      bootstrap_deal_settings if account.feature_enabled?('crm_deals')
      bootstrap_task_settings if account.feature_enabled?('crm_tasks')
    end
  end

  private

  def bootstrap_deal_settings
    return if account.crm_pipelines.exists?

    pipeline = account.crm_pipelines.create!(
      name: DEFAULT_PIPELINE_NAME,
      code: 'sales_pipeline',
      position: 1,
      active: true,
      default: true
    )

    DEFAULT_STAGE_DEFINITIONS.each_with_index do |definition, index|
      pipeline.stages.create!(
        account: account,
        name: definition[:name],
        code: definition[:code],
        outcome: definition[:outcome],
        position: index + 1,
        active: true
      )
    end
  end

  def bootstrap_task_settings
    return if account.crm_task_statuses.exists?

    DEFAULT_TASK_STATUS_DEFINITIONS.each_with_index do |definition, index|
      account.crm_task_statuses.create!(
        name: definition[:name],
        code: definition[:code],
        category: definition[:category],
        position: index + 1,
        active: true,
        default: definition[:default]
      )
    end
  end
end
