# The production input compiler and Reminder schedule/formatters operate on
# unsaved projections. Only association lookup, attachment materialization and
# storage are replaced with this session's JSON; no Reminder callback/job runs.
module Captain::Playground::TouchTools
  private

  def channel_templates
    payload = Outbound::ChannelTemplateCatalog.for(inbox: snapshot_inbox, **@args.symbolize_keys)
    { action: 'list_channel_templates', **payload, simulated: true }
  end

  def touch_inputs
    operation = Captain::Tools::Operations::TouchOperations.new(assistant: @session.assistant,
                                                               conversation: snapshot_conversation, actor: @session.user)
    attachments = snapshot_attachments
    incoming = snapshot_last_message_time(:incoming)
    executor = self
    operation.define_singleton_method(:materialized_attachment_ids) { |**| attachments }
    operation.define_singleton_method(:incoming_customer_message_exists?) { |_record| incoming.present? }
    operation.define_singleton_method(:effective_scheduled_at_for_policy) do |params, remindable:|
      executor.send(:touch_schedule_probe, params, remindable)
    end
    operation
  end

  def touch_schedule_probe(params, remindable)
    return params[:scheduled_at] unless params[:timing_mode].to_s == 'relative'

    probe = snapshot_reminder(params.deep_stringify_keys, remindable: remindable)
    probe.send(:materialize_schedule)
    probe.scheduled_at
  end

  def create_touch
    operation = touch_inputs
    kind = operation.send(:normalized_remindable_kind, @args['remindable_kind'])
    remindable = snapshot_remindable(kind)
    target_inbox = @args['target_inbox_id']
    raise ArgumentError, 'Record is not available' if target_inbox.present? && target_inbox != @data['conversation']['inbox_id']
    template = operation.send(:parsed_hash, @args['template_params'], field_name: 'template_params')
    content_kind = operation.send(:normalized_content_kind, @args['content_kind'], template_params: template)
    operation.send(:validate_touch_content!, body: @args['body'], content_kind: content_kind,
                    template_params: template, attachments_present: snapshot_attachments.any?)
    keys = %w[body scheduled_at relative_anchor relative_offset_minutes timezone target_inbox_id auto_cancel_on_incoming
              attachment_ids artifact_ids repeat_mode repeat_until_at relative_time_mode relative_time_of_day]
    input = keys.index_with { |key| @args[key] }.symbolize_keys
    params = operation.send(:normalized_touch_params, **input, content_kind: content_kind, template_params: template, remindable: remindable)
    scheduled = touch_schedule_probe(params, remindable)
    policy = snapshot_delivery_policy(content_kind: content_kind, template_params: template, attachments: params[:attachments], scheduled_at: scheduled)
    record = params.deep_stringify_keys.merge('id' => @scenario.next_id!, 'status' => 'pending', 'created_at' => Time.current.iso8601,
      'updated_at' => Time.current.iso8601, 'conversation_id' => @data['conversation']['id'], 'remindable_kind' => kind,
      'remindable_type' => remindable.class.name, 'remindable_id' => remindable.id, 'target_contact_id' => caller['id'],
      'target_conversation_id' => @data['conversation']['id'], 'target_inbox_id' => @data['conversation']['inbox_id'], 'scheduled_at' => scheduled)
    record['metadata'] = params[:metadata].merge('delivery_policy' => policy.as_json)
    projection = snapshot_reminder(record, remindable: remindable)
    projection.send(:validate_repeat_requirements)
    projection.send(:validate_relative_time_of_day)
    raise ArgumentError, projection.errors.full_messages.join(', ') if projection.errors.any?

    projection.send(:refresh_fingerprint)
    existing = @data['touches'].find { |item| Reminder::OPEN_STATUSES.include?(item['status']) && item['fingerprint'] == projection.fingerprint }
    return Outbound::ToolPayloadBuilder.touch_payload(action: @tool_id, touch: touch_projection(existing)).merge(simulated: true, delivered: false) if existing
    record['fingerprint'] = projection.fingerprint
    @data['touches'] << JSON.parse(record.to_json)
    Outbound::ToolPayloadBuilder.touch_payload(action: @tool_id, touch: projection).merge(simulated: true, delivered: false)
  end

  def touch_projection(record)
    kind = record.fetch('remindable_kind', 'conversation')
    remindable = if kind == 'conversation'
                   snapshot_conversation
                 else
                   collection, klass = { 'deal' => ['deals', Crm::Deal], 'task' => ['tasks', Crm::Task],
                                         'appointment' => ['appointments', Scheduling::Appointment] }.fetch(kind)
                   native_snapshot(klass, record!(collection, record['remindable_id']))
                 end
    snapshot_reminder(record, remindable: remindable)
  end

  def cancel_touch_record(record, via: 'captain_cancel_touch')
    return record if record['status'] == 'cancelled'
    allowed = via == 'captain_cancel_touches' ? Reminder::OPEN_STATUSES : %w[draft pending]
    raise ArgumentError, 'Touch can only be cancelled while draft or pending' unless allowed.include?(record['status'])

    reason = @args['reason'].presence || Captain::Tools::Operations::TouchOperations::CAPTAIN_CANCEL_REASON
    operation = Captain::Tools::Operations::TouchOperations.new(assistant: @session.assistant, actor: @session.user)
    metadata = operation.send(:cancellation_metadata, cancelled_via: via, reason: reason)
    record.merge!('status' => 'cancelled', 'cancelled_at' => Time.current.iso8601, 'processing_started_at' => nil, 'last_error' => reason,
                  'metadata' => record.fetch('metadata', {}).merge(metadata))
  end

  def cancel_touch
    record = cancel_touch_record(record!('touches', @args.fetch('touch_id')))
    Outbound::ToolPayloadBuilder.touch_payload(action: @tool_id, touch: touch_projection(record)).merge(simulated: true, delivered: false)
  end

  def delete_touch
    record = record!('touches', @args.fetch('touch_id'))
    projection = touch_projection(record)
    raise ArgumentError, 'Only draft, pending, failed, or cancelled touches can be deleted' unless projection.destroyable?

    payload = Outbound::PayloadBuilder.touch_payload(projection)
    @data['touches'].delete(record)
    Outbound::ToolPayloadBuilder.delete_touch_payload(touch_payload: payload).merge(simulated: true, delivered: false)
  end

  def cancel_touches
    operation = Captain::Tools::Operations::TouchOperations.new(assistant: @session.assistant, actor: @session.user)
    kind = operation.send(:normalized_remindable_kind, @args['remindable_kind'])
    remindable = snapshot_remindable(kind)
    plan = selected_touch_plan(kind)
    records = @data['touches'].select do |record|
      record['remindable_id'] == remindable.id && record['remindable_type'] == remindable.class.name &&
        (!plan || record['reminder_group_id'] == plan['id'])
    end
    bulk = Reminders::BulkCancelService.new(account: @session.account, remindable: remindable)
    cancellable, skipped = records.partition { |record| bulk.send(:cancellable_status?, touch_projection(record)) }
    cancellable.each { |record| cancel_touch_record(record, via: 'captain_cancel_touches') }
    enrollments = @data['touch_plan_enrollments'].select do |record|
      record['remindable_id'] == remindable.id && record['remindable_type'] == remindable.class.name &&
        %w[active paused].include?(record['status']) && (!plan || record['reminder_group_id'] == plan['id'])
    end
    enrollments.each { |record| record.merge!('status' => 'cancelled', 'cancelled_at' => Time.current.iso8601) }
    result = { found_count: records.size, cancellable_count: cancellable.size, cancelled_count: cancellable.size,
      already_terminal_count: skipped.count { |record| !Reminder::OPEN_STATUSES.include?(record['status']) },
      skipped_count: skipped.size, failed_count: 0, remaining_open_count: skipped.count { |record| Reminder::OPEN_STATUSES.include?(record['status']) },
      cancelled_enrollment_count: enrollments.size, cancelled_enrollment_ids: enrollments.pluck('id'), enrollment_failed_count: 0, enrollment_failures: [],
      remaining_open_enrollment_count: 0, cancelled_touch_ids: cancellable.pluck('id'), failures: [],
      skipped_touches: skipped.map { |record| bulk.send(:skipped_touch_payload, touch_projection(record), bulk.send(:skip_reason_for, touch_projection(record))) },
      scope: { account_id: @session.account.id, remindable_type: remindable.class.name, remindable_id: remindable.id, reminder_group_id: plan&.fetch('id', nil) }.compact,
      reason: @args['reason'].presence || Captain::Tools::Operations::TouchOperations::CAPTAIN_CANCEL_REASON,
      remindable: Outbound::PayloadBuilder.remindable_payload(remindable), touch_plan: plan&.symbolize_keys }
    Outbound::ToolPayloadBuilder.cancel_touches_payload(result: result).merge(simulated: true, delivered: false)
  end

  def selected_touch_plan(kind)
    return unless @args['touch_plan_id'].present? || @args['touch_plan_name'].present?

    plan = @data['touch_plans'].find do |item|
      item['archived_at'].blank? && (@args['touch_plan_name'].present? ? item['name'].to_s.casecmp?(@args['touch_plan_name'].strip) : item['id'] == @args['touch_plan_id'])
    end
    raise ActiveRecord::RecordNotFound, 'Touch plan not found' unless plan
    projection = native_snapshot(ReminderGroup, plan)
    unless projection.entity_kind_supported?(kind)
      raise ArgumentError, 'Touch plan does not support this entity kind'
    end
    plan
  end

  def record_timeline(kind, record, action)
    @data['timelines'] << { 'id' => @scenario.next_id!, 'entity_kind' => kind, 'record_id' => record['id'],
      'id_key' => "#{kind}:#{record['id']}", 'type' => 'event', 'occurred_at' => Time.current.iso8601,
      'event_type' => action, 'title' => action, 'meta' => {}, 'sort_id' => @data['next_id'] }
  end

  def record_timeline_details
    kind = @tool_id == 'get_deal_timeline' ? 'deal' : 'task'
    record = kind == 'deal' ? deal!(@args['deal_id']) : task!(@args['task_id'])
    service = Crm::Timelines::BaseService.allocate
    service.instance_variable_set(:@params, @args.symbolize_keys)
    items = @data['timelines'].select { |item| item['entity_kind'] == kind && item['record_id'] == record['id'] }
    items = items.map { |item| item.deep_symbolize_keys.merge(occurred_at: Time.iso8601(item.fetch('occurred_at')), sort_id: item.fetch('sort_id', item['id'])) }
    before = service.send(:before_time)
    items = items.select { |item| item[:occurred_at] < before } if before
    service.send(:timeline_response, items).merge(simulated: true)
  end
end
