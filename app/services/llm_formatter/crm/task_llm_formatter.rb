module LlmFormatter::Crm
  class TaskLlmFormatter < LlmFormatter::DefaultLlmFormatter
    def format(*)
      sections = []
      sections << "Task ID: ##{@record.id}"
      sections << "Title: #{@record.title}"
      sections << "Description: #{@record.description.presence || 'Not set'}"
      sections << "Status: #{@record.status&.name || 'Not set'}"
      sections << "Priority: #{@record.priority || 'Not set'}"
      sections << "Assignee: #{@record.assignee&.name || 'Not set'}"
      sections << "Team: #{@record.team&.name || 'Not set'}"
      sections << "Deal: #{@record.deal&.title || 'Not set'}"
      sections << "Start At: #{@record.start_at || 'Not set'}"
      sections << "Due At: #{@record.due_at || 'Not set'}"
      sections << "Completed At: #{@record.completed_at || 'Not set'}"
      sections << "Archived: #{@record.archived_at.present?}"
      sections << "Custom Attributes: #{@record.custom_attributes.to_json}"
      sections.join("\n")
    end
  end
end
