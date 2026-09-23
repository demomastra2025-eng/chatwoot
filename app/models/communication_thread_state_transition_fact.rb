class CommunicationThreadStateTransitionFact < ApplicationRecord
  EVENT_KINDS = %w[created routing_changed resolved reopened state_changed].freeze
  ACTOR_KINDS = %w[user contact captain system automation unknown].freeze
  IMMUTABLE_ATTRIBUTES = column_names.freeze

  belongs_to :account

  validates :communication_thread_id_snapshot, :thread_display_id_snapshot, :contact_id_snapshot,
            :occurred_at, :requested_occurred_at, :reliable_since, :source_event_id, :idempotency_key, presence: true
  validates :event_kind, inclusion: { in: EVENT_KINDS }
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :source, presence: true
  validates :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }, unless: :database_fallback?
  validates :source_version, numericality: { only_integer: true, equal_to: 1 }
  validate :effective_change_is_consistent
  validate :reliable_boundary_is_consistent
  validate :immutable_fact, on: :update

  def readonly?
    persisted?
  end

  private

  def database_fallback?
    source == 'database_projection_fallback'
  end

  def effective_change_is_consistent
    return if event_kind == 'created'
    return if from_assignee_id != to_assignee_id || from_team_id != to_team_id || from_status != to_status

    errors.add(:base, 'state transition fact must describe an effective change')
  end

  def reliable_boundary_is_consistent
    return if reliable_since.blank? || requested_occurred_at.blank? || occurred_at.blank?

    errors.add(:reliable_since, 'must not be after occurred_at') if reliable_since > occurred_at
    errors.add(:requested_occurred_at, 'must not be after occurred_at') if requested_occurred_at > occurred_at
  end

  def immutable_fact
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Communication thread state transition fact is immutable: #{changed.join(', ')}") if changed.any?
  end
end
