class Telephony::LogicalCallOccurrence < ApplicationRecord
  self.table_name = 'telephony_logical_call_occurrences'

  OCCURRENCE_KINDS = %w[attempted connected terminal].freeze
  ACTOR_KINDS = %w[human ai_agent system unknown].freeze
  IMMUTABLE_ATTRIBUTES = column_names.freeze

  belongs_to :account

  scope :current_revision, lambda {
    where.not(id: unscoped.where.not(supersedes_occurrence_id: nil).select(:supersedes_occurrence_id))
  }

  validates :logical_call_identity, :logical_call_ref, :source_id, :source_ref, :provider,
            :direction, :occurred_at, :reliable_since, presence: true
  validates :occurrence_kind, inclusion: { in: OCCURRENCE_KINDS }
  validates :source_kind, inclusion: { in: ['telephony_call_session'] }
  validates :direction, inclusion: { in: Telephony::CallSession::ALLOWED_DIRECTIONS }
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :reliability, inclusion: { in: %w[exact unknown] }
  validates :source_version, :definition_version, numericality: { only_integer: true, equal_to: 1 }
  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :duration_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :occurrence_timestamps_are_consistent
  validate :actor_snapshot_is_consistent
  validate :source_belongs_to_account
  validate :snapshot_references_belong_to_account
  validate :immutable_occurrence, on: :update

  def readonly?
    persisted?
  end

  private

  def occurrence_timestamps_are_consistent
    validate_required_timestamps
    validate_non_terminal_fields unless occurrence_kind == 'terminal'
  end

  def validate_required_timestamps
    if occurrence_kind == 'connected' && connected_at.blank? && reliability != 'unknown'
      errors.add(:connected_at, 'is required for an exact connected occurrence')
    end
    errors.add(:terminal_at, 'is required for terminal occurrence') if occurrence_kind == 'terminal' && terminal_at.blank?
  end

  def validate_non_terminal_fields
    errors.add(:terminal_at, 'is only valid for terminal occurrence') if terminal_at.present?
    errors.add(:duration_seconds, 'is only valid for terminal occurrence') if duration_seconds.present?
    errors.add(:duration_source, 'is only valid for terminal occurrence') if duration_source.present?
    errors.add(:terminal_status, 'is only valid for terminal occurrence') if terminal_status.present?
  end

  def actor_snapshot_is_consistent
    if actor_kind != 'human' && (actor_id_snapshot.present? || actor_team_id_snapshot.present?)
      errors.add(:actor_kind, 'must be human with user or team snapshots')
    end
    return if actor_kind == 'ai_agent' || (assistant_id_snapshot.blank? && assistant_name_snapshot.blank?)

    errors.add(:actor_kind, 'must be ai_agent with assistant snapshots')
  end

  def source_belongs_to_account
    return if source_id.blank? || account_id.blank?
    return if Telephony::CallSession.exists?(
      id: source_id,
      account_id: account_id,
      external_call_ref: source_ref,
      provider: provider,
      direction: direction
    )

    errors.add(:source_id, 'must identify the matching call session in the same account')
  end

  def snapshot_references_belong_to_account
    validate_account_reference(:inbox_id_snapshot, Inbox)
    validate_account_reference(:contact_id_snapshot, Contact)
    validate_account_reference(:conversation_id_snapshot, Conversation)
    validate_account_reference(:communication_thread_id_snapshot, CommunicationThread)
    validate_account_reference(:actor_team_id_snapshot, Team)
    validate_actor_reference
    validate_assistant_reference
  end

  def validate_account_reference(attribute, model)
    value = public_send(attribute)
    return if value.blank? || account_id.blank? || model.exists?(id: value, account_id: account_id)
    return if attribute == :actor_team_id_snapshot && historical_connected_snapshot?(attribute, value)

    errors.add(attribute, 'must belong to the same account')
  end

  def validate_actor_reference
    return if actor_id_snapshot.blank? || account_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: actor_id_snapshot)
    return if historical_connected_snapshot?(:actor_id_snapshot, actor_id_snapshot)

    errors.add(:actor_id_snapshot, 'must identify a workspace member in the same account')
  end

  def validate_assistant_reference
    return if assistant_id_snapshot.blank? || account_id.blank?
    return if Captain::Assistant.exists?(id: assistant_id_snapshot, account_id: account_id)
    return if historical_connected_snapshot?(:assistant_id_snapshot, assistant_id_snapshot)

    errors.add(:assistant_id_snapshot, 'must identify an assistant in the same account')
  end

  def historical_connected_snapshot?(attribute, value)
    occurrence_kind == 'terminal' && self.class.where(
      account_id: account_id,
      logical_call_identity: logical_call_identity,
      occurrence_kind: 'connected'
    ).exists?(attribute => value)
  end

  def immutable_occurrence
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Telephony logical call occurrence is immutable: #{changed.join(', ')}") if changed.any?
  end
end
