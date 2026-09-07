class Crm::Events::Writer
  AUDITABLE_CHANGE_KEYS = %w[
    archived_at
    assignee_id
    cancellation_reason
    cancelled_at
    cancelled_by_id
    closed_at
    completed_at
    completed_by_id
    due_at
    due_on
    owner_id
    pipeline_id
    position
    priority
    stage_id
    start_at
    status_id
    task_outcome_id
    task_type_id
    reschedule_count
    team_id
  ].freeze
  OPTION_KEYS = %i[
    after_data before_data causation_id command_key correlation_id meta source
  ].freeze

  def self.record!(account:, eventable:, actor:, event_type:, **options)
    assert_known_options!(options)
    attributes = base_attributes(eventable: eventable, actor: actor, event_type: event_type)
                 .merge(audit_attributes(options))
                 .merge(execution_attributes(actor, options))
    create_event!(account, attributes)
  end

  def self.base_attributes(eventable:, actor:, event_type:)
    {
      eventable: eventable,
      actor: actor,
      actor_kind: actor&.class&.base_class&.name || 'System',
      event_type: event_type,
      schema_version: 1,
      created_at: Time.current
    }
  end
  private_class_method :base_attributes

  def self.audit_attributes(options)
    meta = options.fetch(:meta, {})
    changes = meta.to_h.with_indifferent_access[:changes].to_h
    {
      meta: meta,
      before_data: options[:before_data] || snapshot_changes(changes, 0),
      after_data: options[:after_data] || snapshot_changes(changes, 1),
      correlation_id: options[:correlation_id].presence || SecureRandom.uuid,
      causation_id: options[:causation_id],
      command_key: options[:command_key]
    }
  end
  private_class_method :audit_attributes

  def self.execution_attributes(actor, options)
    performed_by = Current.executed_by
    {
      source: options[:source].presence || inferred_source(actor, performed_by),
      performed_by_type: persisted_record_type(performed_by),
      performed_by_id: persisted_record_id(performed_by)
    }
  end
  private_class_method :execution_attributes

  def self.assert_known_options!(options)
    unknown_options = options.keys - OPTION_KEYS
    raise ArgumentError, "Unknown event options: #{unknown_options.join(', ')}" if unknown_options.present?
  end
  private_class_method :assert_known_options!

  def self.create_event!(account, attributes)
    return account.crm_events.create!(attributes) if attributes[:command_key].blank?

    identity = {
      eventable: attributes[:eventable],
      event_type: attributes[:event_type],
      command_key: attributes[:command_key]
    }
    scope = account.crm_events.where(identity)
    scope.first || account.crm_events.create!(attributes)
  rescue ActiveRecord::RecordNotUnique
    scope.first!
  end
  private_class_method :create_event!

  def self.snapshot_changes(changes, index)
    changes.each_with_object({}) do |(key, values), snapshot|
      next unless key.to_s.in?(AUDITABLE_CHANGE_KEYS)

      snapshot[key] = Array(values)[index]
    end
  end
  private_class_method :snapshot_changes

  def self.inferred_source(actor, performed_by)
    return 'automation' if performed_by.is_a?(AutomationRule)
    return 'captain' if defined?(Captain::Assistant) && performed_by.is_a?(Captain::Assistant)
    return 'api' if actor.present?

    'system'
  end
  private_class_method :inferred_source

  def self.persisted_record_type(record)
    record.class.base_class.name if record.is_a?(ApplicationRecord) && record.persisted?
  end
  private_class_method :persisted_record_type

  def self.persisted_record_id(record)
    record.id if record.is_a?(ApplicationRecord) && record.persisted?
  end
  private_class_method :persisted_record_id
end
