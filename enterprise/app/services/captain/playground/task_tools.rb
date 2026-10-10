module Captain::Playground::TaskTools
  TASK_FIELDS = %w[title description activity_type outcome outcome_note priority start_at due_at assignee_id team_id
                   all_day due_on schedule_timezone task_type_id task_outcome_id external_ref].freeze
  TASK_STATUSES = Crm::TaskCatalogs::Provisioner::TASK_STATUS_DEFINITIONS.each_with_index.map do |status, index|
    status.stringify_keys.merge('id' => index + 1, 'name' => Crm::TaskCatalogs::SeedNames.status_name(status[:code], 'ru'))
  end.freeze

  private

  def task!(id = nil)
    record = record!('tasks', id || @data['selection']['task_id'] || @context.state.dig(:task, :id))
    raise ArgumentError, 'Record is not available' unless record['contact_id'] == caller['id']

    record
  end

  def task_details
    { task: native_task_payload(task!(@args.fetch('task_id'))), simulated: true }
  end

  def task_payload(record)
    record.slice('title', 'status_id', 'activity_type', 'outcome', 'outcome_note', 'priority', 'due_at', 'completed_at').symbolize_keys.merge(
      action: @tool_id, task: native_task_payload(record), task_id: record['id'], simulated: true
    )
  end

  def create_task
    raise ArgumentError, 'Task title is required' if @args['title'].blank?
    require_conversation!(@args['originating_conversation_id'])
    deal = deal!(@args['deal_id']) if @args['deal_id']
    record = { 'id' => @scenario.next_id!, 'contact_id' => caller['id'], 'deal_id' => deal&.fetch('id', nil),
               'activity_type' => 'task', 'priority' => 'medium', 'originating_conversation_id' => @data['conversation']['id'],
               'custom_attributes' => custom_attributes_for('task'), 'created_at' => Time.current.iso8601,
               'updated_at' => Time.current.iso8601 }.merge(task_attributes)
    apply_task_status(record, selected_task_status)
    validate_native_task!(record)
    @data['tasks'] << record
    record_timeline('task', record, @tool_id)
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
    snapshot_assignment_account.users.find(attributes['assignee_id']) if attributes['assignee_id'].present?
    snapshot_assignment_account.teams.find(attributes['team_id']) if attributes['team_id'].present?
    %w[task_type_id task_outcome_id].each do |key|
      record!(key == 'task_type_id' ? 'task_types' : 'task_outcomes', attributes[key]) if attributes[key].present?
    end

    if @args['custom_attributes']
      attributes['custom_attributes'] =
        custom_attributes_for('task', record: record)
    end
    attributes
  end

  def selected_task_status
    statuses = @data['task_statuses'].reject { |status| status['active'] == false }
    return statuses.find { |status| status['default'] == true } || statuses.first unless %w[status_id status_name status_code].any? { |field| @args[field].present? }

    statuses.find do |status|
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
    record['updated_at'] = Time.current.iso8601
    validate_native_task!(record)
    record_timeline('task', record, @tool_id)
    task_payload(record)
  end

  def change_task_status
    raise ArgumentError, 'Task status is required' unless %w[status_id status_name status_code].any? { |field| @args[field].present? }

    record = task!(@args['task_id'])
    apply_task_status(record, selected_task_status)
    validate_native_task!(record)
    record_timeline('task', record, @tool_id)
    task_payload(record)
  end

  def complete_task
    record = task!(@args['task_id'])
    record.merge!(task_attributes(record))
    apply_task_status(record, @data['task_statuses'].find { |status| status['code'] == 'done' } || raise(ArgumentError, 'Task status is not available'))
    validate_native_task!(record)
    record_timeline('task', record, @tool_id)
    task_payload(record)
  end

  def search_tasks
    require_caller_filter!
    snapshot_assignment_account.users.find(@args['assignee_id']) if @args['assignee_id'].present?
    snapshot_assignment_account.teams.find(@args['team_id']) if @args['team_id'].present?
    deal!(@args['deal_id']) if @args['deal_id'].present?
    records = @data['tasks'].select { |task| task['contact_id'] == caller['id'] && task['archived_at'].present? == (@args['archived'] == true) }
    %w[deal_id activity_type outcome priority assignee_id team_id].each do |field|
      records = records.select { |task| task[field].to_s == @args[field].to_s } if @args[field]
    end
    records = records.select { |task| task['status_name'].casecmp?(@args['status_name']) } if @args['status_name'].present?
    if @args['query'].present?
      records = records.select do |task|
        [task['title'], task['description'], task['external_ref']].join(' ').downcase.include?(@args['query'].downcase)
      end
    end
    records.sort_by! { |task| [task['due_at'].blank? ? 1 : 0, task['due_at'].to_s, -parse_sort_time(task['updated_at']), -task['id']] }
    limit = Captain::Tools::Copilot::BaseAccountTool.allocate.send(:parse_limit, @args['limit'])
    { tasks: records.first(limit).map { |record| native_task_payload(record) }, total_count: records.size, simulated: true }
  end

  def parse_sort_time(value)
    value.present? ? Time.iso8601(value).to_i : 0
  end

  def native_task_projection(record)
    native_snapshot(Crm::Task, record).tap do |projection|
      status = @data['task_statuses'].find { |item| item['id'] == record['status_id'] }
      load_snapshot_association(projection, :status, status && native_snapshot(Crm::TaskStatus, status))
      { task_type: ['task_types', Crm::TaskType], task_outcome: ['task_outcomes', Crm::TaskOutcome] }.each do |association, (collection, klass)|
        item = @data[collection].find { |value| value['id'] == record["#{association}_id"] }
        load_snapshot_association(projection, association, item && native_snapshot(klass, item))
      end
      deal = @data['deals'].find { |item| item['id'] == record['deal_id'] }
      load_snapshot_association(projection, :deal, deal && native_snapshot(Crm::Deal, deal))
      %i[assignee team creator completed_by cancelled_by originating_conversation].each do |association|
        load_snapshot_association(projection, association, nil)
      end
    end
  end

  def native_task_payload(record)
    projection = native_task_projection(record)
    catalog = Object.new
    catalog.define_singleton_method(:task_type_for) { |_task| projection.task_type }
    catalog.define_singleton_method(:task_outcome_for) { |_task, **| projection.task_outcome }
    Crm::PayloadBuilder.task(projection, catalog_snapshot: catalog).merge(status_name: record['status_name'], status_code: record['status_code'],
      status_category: record['status_category'], contact_id: record['contact_id'])
  end

  def validate_native_task!(record)
    projection = native_task_projection(record)
    # These production normalizers are pure. Catalog lookup, position allocation,
    # persistence callbacks and jobs stay outside this snapshot adapter.
    %i[normalize_activity_type normalize_context_kind normalize_title normalize_description normalize_outcome
       normalize_outcome_note normalize_schedule sync_catalog_snapshots].each { |method| projection.send(method) }
    Crm::Task.validators.each do |validator|
      next if validator.is_a?(ActiveRecord::Validations::UniquenessValidator)
      next unless Array(validator.options[:if]).all? { |condition| native_task_validation_condition?(projection, condition) }
      next if Array(validator.options[:unless]).any? { |condition| native_task_validation_condition?(projection, condition) }

      validator.validate(projection)
    end
    projection.send(:sales_context_requires_deal)
    projection.send(:related_records_belong_to_account)
    raise ArgumentError, projection.errors.full_messages.join(', ') if projection.errors.any?

    record.merge!(projection.attributes.slice('title', 'description', 'context_kind', 'activity_type', 'outcome', 'outcome_note',
      'schedule_timezone', 'all_day', 'due_on', 'start_at', 'due_at').as_json)

    if record['external_ref'].present? && @data['tasks'].any? { |item| item['id'] != record['id'] && item['external_ref'] == record['external_ref'] }
      raise ArgumentError, 'External ref has already been taken'
    end
  end

  def native_task_validation_condition?(projection, condition)
    return projection.send(condition) unless condition.is_a?(Proc)

    condition.arity.zero? ? projection.instance_exec(&condition) : condition.call(projection)
  end
end
