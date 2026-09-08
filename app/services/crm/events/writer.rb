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

  def self.record!(account:, eventable:, actor:, event_type:, meta: {}, source: nil, before_data: nil, after_data: nil,
                   correlation_id: nil, causation_id: nil, command_key: nil)
    changes = meta.to_h.with_indifferent_access[:changes].to_h
    performed_by = Current.executed_by
    attributes = {
      eventable: eventable,
      actor: actor,
      actor_kind: actor&.class&.base_class&.name || 'System',
      event_type: event_type,
      meta: meta,
      source: source.presence || inferred_source(actor, performed_by),
      before_data: before_data || snapshot_changes(changes, 0),
      after_data: after_data || snapshot_changes(changes, 1),
      correlation_id: correlation_id.presence || SecureRandom.uuid,
      causation_id: causation_id,
      command_key: command_key,
      performed_by_type: persisted_record_type(performed_by),
      performed_by_id: persisted_record_id(performed_by),
      schema_version: 1,
      created_at: Time.current
    }

    create_event!(account, attributes)
  end

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
