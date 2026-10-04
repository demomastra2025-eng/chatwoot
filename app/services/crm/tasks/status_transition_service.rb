class Crm::Tasks::StatusTransitionService < Crm::BaseWriteService
  def initialize(account:, task:, params:, actor: nil, **transition_options)
    @task = task
    @broadcast = transition_options.fetch(:broadcast, true)
    @catalogs_provisioned = transition_options.fetch(:catalogs_provisioned, false)
    assert_known_transition_options!(transition_options)
    super(account: account, params: params, record: @task, actor: actor)
  end

  def perform
    target_status = account.crm_task_statuses.find(params[:status_id])
    service_class = case target_status.category
                    when 'done' then Crm::Tasks::CompleteService
                    when 'cancelled' then Crm::Tasks::CancelService
                    else Crm::Tasks::ReopenService
                    end
    service_class.new(
      account: account, task: task, actor: actor, params: params,
      broadcast: @broadcast, catalogs_provisioned: @catalogs_provisioned
    ).perform
  end

  private

  attr_reader :task

  def assert_known_transition_options!(options)
    unknown_options = options.keys - %i[broadcast catalogs_provisioned]
    raise ArgumentError, "Unknown transition options: #{unknown_options.join(', ')}" if unknown_options.present?
  end
end
