class Captain::Tools::Copilot::SearchConversationsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_conversations'
  end

  description 'Search conversations by status, priority, contact, or labels'
  param :status, type: :string, desc: 'Conversation status: open, resolved, pending, or snoozed', required: false
  param :contact_id, type: :number, desc: 'Contact ID', required: false
  param :priority, type: :string, desc: 'Conversation priority: low, medium, high, or urgent', required: false
  param :labels, type: :array, desc: 'Optional list of labels to match', required: false
  param :limit, type: :number, desc: 'Maximum number of conversations to return', required: false

  def execute(status: nil, contact_id: nil, priority: nil, labels: nil, limit: nil)
    filter_error = validate_filters(status: status, priority: priority)
    return filter_error if filter_error

    conversations = filtered_conversations(status: status, contact_id: contact_id, priority: priority, labels: labels)
    total_count = conversations.count
    records = conversations.limit(parse_limit(limit)).map { |conversation| conversation_payload(conversation) }

    formatted_payload(
      filters: {
        status: valid_status?(status) ? status : nil,
        contact_id: contact_id,
        priority: valid_priority?(priority) ? priority : nil,
        labels: normalized_labels(labels)
      }.compact,
      total_count: total_count,
      conversations: records
    )
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  def validate_filters(status:, priority:)
    return tool_failure("Invalid conversation status: #{status}") if status.present? && !valid_status?(status)
    return tool_failure("Invalid conversation priority: #{priority}") if priority.present? && !valid_priority?(priority)
  end

  def filtered_conversations(status:, contact_id:, priority:, labels:)
    conversations = permissible_conversations.includes(:contact, :assignee, :inbox).order(last_activity_at: :desc, id: :desc)
    conversations = conversations.where(contact_id: contact_id) if contact_id.present?
    conversations = conversations.where(status: status) if valid_status?(status)
    conversations = conversations.where(priority: priority) if valid_priority?(priority)

    label_list = normalized_labels(labels)
    conversations = conversations.tagged_with(label_list, any: true) if label_list.present?
    conversations
  end

  def normalized_labels(labels)
    Array(labels).flatten.filter_map do |label|
      text = label.to_s.strip
      text.presence
    end.uniq
  end

  def valid_status?(status)
    status.present? && Conversation.statuses.key?(status)
  end

  def valid_priority?(priority)
    priority.present? && Conversation.priorities.key?(priority)
  end

  def permissible_conversations
    Conversations::PermissionFilterService.new(account.conversations, @user, account).perform
  end

  def conversation_payload(conversation)
    {
      id: conversation.id,
      display_id: conversation.display_id,
      status: conversation.status,
      priority: conversation.priority,
      contact_id: conversation.contact_id,
      contact_name: conversation.contact&.name,
      assignee_id: conversation.assignee_id,
      assignee_name: conversation.assignee&.name,
      inbox_id: conversation.inbox_id,
      inbox_name: conversation.inbox&.name,
      labels: conversation.label_list.to_a,
      last_activity_at: conversation.last_activity_at&.iso8601,
      created_at: conversation.created_at&.iso8601,
      updated_at: conversation.updated_at&.iso8601
    }
  end
end
