module Crm::ToolPayloadBuilder
  module_function

  def deal_payload(action:, deal:)
    deal_data = Crm::PayloadBuilder.ai_deal(deal)

    {
      action: action,
      deal_id: deal_data[:id],
      pipeline_id: deal_data[:pipeline_id],
      stage_id: deal_data[:stage_id],
      title: deal_data[:title],
      amount: deal_data[:amount],
      currency: deal_data[:currency],
      deal: deal_data
    }.compact
  end

  def task_payload(action:, task:)
    task_data = Crm::PayloadBuilder.task(task)

    {
      action: action,
      task_id: task_data[:id],
      status_id: task_data[:status_id],
      title: task_data[:title],
      priority: task_data[:priority],
      due_at: task_data[:due_at],
      completed_at: task_data[:completed_at],
      task: task_data
    }.compact
  end
end
