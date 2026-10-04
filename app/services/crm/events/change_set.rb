class Crm::Events::ChangeSet
  DEAL_KEYS = %w[
    title description amount_minor currency expected_close_on win_probability closed_at
    closing_reasons external_ref pipeline_id stage_id owner_id creator_id team_id company_id
    originating_conversation_id originating_communication_thread_id primary_contact_id archived_at
    custom_attributes position
  ].freeze
  TASK_KEYS = %w[
    title description activity_type outcome outcome_note priority status_id assignee_id creator_id
    team_id start_at due_at due_on all_day schedule_timezone completed_at completed_by_id cancelled_at
    cancelled_by_id cancellation_reason reschedule_count task_type_id task_outcome_id position
    external_ref archived_at custom_attributes context_kind deal_id originating_conversation_id
  ].freeze
  KEYS_BY_KIND = { 'Crm::Deal' => DEAL_KEYS, 'Crm::Task' => TASK_KEYS }.freeze

  def self.resolve(record:, meta:, before_data:, after_data:)
    explicit = meta.to_h.with_indifferent_access[:changes]
    filtered_explicit = filter(record: record, changes: explicit)
    return filtered_explicit if filtered_explicit.present?

    build(record: record, before_data: before_data, after_data: after_data)
  end

  def self.build(record:, before_data:, after_data:)
    keys = keys_for(record)
    before_values = before_data.to_h.with_indifferent_access
    after_values = after_data.to_h.with_indifferent_access

    keys.each_with_object({}) do |key, changes|
      next unless before_values.key?(key) || after_values.key?(key)

      previous = before_values[key]
      current = after_values[key]
      changes[key] = [previous, current] if previous != current
    end
  end

  def self.filter(record:, changes:)
    keys = keys_for(record)
    changes.to_h.with_indifferent_access.each_with_object({}) do |(key, values), filtered|
      field = key.to_s
      pair = Array(values)
      next unless field.in?(keys) && pair.length == 2 && pair[0] != pair[1]

      filtered[field] = pair
    end
  end

  def self.keys_for(record)
    KEYS_BY_KIND.fetch(record.class.base_class.name, [])
  end
  private_class_method :keys_for
end
