module Captain::Playground::TaskTools
  TASK_FIELDS = %w[title description activity_type outcome outcome_note priority start_at due_at].freeze
  TASK_STATUSES = Crm::TaskCatalogs::Provisioner::TASK_STATUS_DEFINITIONS.each_with_index.map do |status, index|
    status.stringify_keys.merge('id' => index + 1, 'name' => Crm::TaskCatalogs::SeedNames.status_name(status[:code], 'ru'))
  end.freeze

  private

  def task!(id = nil)
    record = record!('tasks', id || @context.state.dig(:task, :id))
    raise ArgumentError, 'Record is not available' unless record['contact_id'] == caller['id']

    record
  end

  def task_details
    { task: task!(@args.fetch('task_id')).deep_dup, simulated: true }
  end

  def task_payload(record)
    record.slice('title', 'status_id', 'activity_type', 'outcome', 'outcome_note', 'priority', 'due_at', 'completed_at').symbolize_keys.merge(
      action: @tool_id, task: record.deep_dup, task_id: record['id'], simulated: true
    )
  end

  def create_task
    raise ArgumentError, 'Task title is required' if @args['title'].blank?
    raise ArgumentError, 'No staff assignment exists in this Trial scenario' if @args['assignee_id'].present? || @args['team_id'].present?

    require_conversation!(@args['originating_conversation_id'])
    deal = deal!(@args['deal_id']) if @args['deal_id']
    record = { 'id' => @scenario.next_id!, 'contact_id' => caller['id'], 'deal_id' => deal&.fetch('id', nil),
               'activity_type' => 'task', 'priority' => 'medium', 'originating_conversation_id' => @data['conversation']['id'],
               'custom_attributes' => json_object(@args['custom_attributes']) }.merge(task_attributes)
    apply_task_status(record, selected_task_status)
    @data['tasks'] << record
    task_payload(record)
  end

  def task_attributes(record = nil)
    attributes = @args.slice(*TASK_FIELDS)
    raise ArgumentError, 'Task title is required' if attributes.key?('title') && attributes['title'].blank?

    %w[activity_type priority outcome].each do |field|
      allowed = { 'activity_type' => Crm::Task::ACTIVITY_TYPES, 'priority' => Crm::Task::PRIORITIES, 'outcome' => Crm::Task::OUTCOMES }[field]
      raise ArgumentError, "Invalid task #{field}" if attributes[field].present? && !allowed.include?(attributes[field])
    end
    times = record.to_h.merge(attributes)
    start = parse_time(times['start_at']) if times['start_at'].present?
    due = parse_time(times['due_at']) if times['due_at'].present?
    raise ArgumentError, 'Task end must not be before its start' if start && due && due < start

    if @args['custom_attributes']
      attributes['custom_attributes'] =
        record.to_h.fetch('custom_attributes', {}).merge(json_object(@args['custom_attributes']))
    end
    attributes
  end

  def selected_task_status
    return TASK_STATUSES.first unless %w[status_id status_name status_code].any? { |field| @args[field].present? }

    TASK_STATUSES.find do |status|
      status['id'].to_s == @args['status_id'].to_s || status['name'].casecmp?(@args['status_name'].to_s) || status['code'] == @args['status_code']
    end || raise(ArgumentError, 'Task status is not available')
  end

  def apply_task_status(record, status)
    record.merge!('status_id' => status['id'], 'status_name' => status['name'], 'status_code' => status['code'],
                  'status_category' => status['category'])
    record['completed_at'] = status['category'] == 'done' ? record['completed_at'] || Time.current.iso8601 : nil
  end

  def update_task
    record = task!(@args['task_id'])
    record.merge!(task_attributes(record))
    task_payload(record)
  end

  def change_task_status
    raise ArgumentError, 'Task status is required' unless %w[status_id status_name status_code].any? { |field| @args[field].present? }

    record = task!
    apply_task_status(record, selected_task_status)
    task_payload(record)
  end

  def complete_task
    record = task!
    record.merge!(task_attributes(record))
    apply_task_status(record, TASK_STATUSES.find { |status| status['code'] == 'done' })
    task_payload(record)
  end

  def search_tasks
    require_caller_filter!
    records = @args['archived'] == true ? [] : @data['tasks'].select { |task| task['contact_id'] == caller['id'] }
    %w[deal_id activity_type outcome priority assignee_id team_id].each do |field|
      records = records.select { |task| task[field].to_s == @args[field].to_s } if @args[field]
    end
    records = records.select { |task| task['status_name'].casecmp?(@args['status_name']) } if @args['status_name'].present?
    if @args['query'].present?
      records = records.select do |task|
        [task['title'], task['description']].join(' ').downcase.include?(@args['query'].downcase)
      end
    end
    { tasks: records.last(Integer(@args['limit'] || 20).clamp(1, 50)).deep_dup, total_count: records.size, simulated: true }
  end
end
