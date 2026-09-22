class CommunicationThreadParticipantLifecycleFact < ApplicationRecord
  ACTIONS = %w[add remove clear retain promote resolve].freeze
  ACTOR_KINDS = %w[system user customer captain automation].freeze
  IMMUTABLE_ATTRIBUTES = column_names.freeze
  ACTOR_TYPES_BY_KIND = {
    'system' => ['System'],
    'user' => ['User'],
    'customer' => ['Contact'],
    'captain' => ['Captain::Assistant'],
    'automation' => %w[AssignmentPolicy AutomationRule Inbox]
  }.freeze

  belongs_to :account
  belongs_to :communication_thread

  validates :participant_type, inclusion: { in: ['User'] }
  validates :participant_id, :occurred_at, :correlation_id, :idempotency_key, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :actor_type, presence: true
  validates :schema_version, numericality: { only_integer: true, equal_to: 1 }
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validate :thread_belongs_to_account
  validate :participant_belongs_to_account
  validate :actor_identity_is_consistent
  validate :reliable_boundary_is_consistent
  validate :immutable_fact, on: :update

  class << self
    def validate_actor!(actor:, account_id:)
      actor_attributes(actor, account_id)
      true
    end

    def record!(membership:, actor:, action:, reason:, identity:)
      actor_attributes = actor_attributes(actor, membership.account_id)
      create!(
        account_id: membership.account_id,
        communication_thread_id: membership.communication_thread_id,
        participant_type: 'User',
        participant_id: membership.user_id,
        **actor_attributes,
        action: action,
        reason: reason,
        occurred_at: identity[:occurred_at],
        reliable_since: reliable_since_for(membership, action, identity[:occurred_at]),
        correlation_id: identity[:correlation_id],
        idempotency_key: identity[:key],
        schema_version: 1
      )
    end

    private

    def actor_attributes(actor, account_id)
      return { actor_kind: 'system', actor_type: 'System', actor_id: nil } if actor.blank?

      actor_type = actor.class.base_class.name
      actor_kind = ACTOR_TYPES_BY_KIND.find { |_kind, types| types.include?(actor_type) }&.first
      raise ArgumentError, "unsupported participant lifecycle actor: #{actor_type}" if actor_kind.blank?
      raise ActiveRecord::RecordNotFound, 'participant lifecycle actor belongs to another account' unless actor_in_account?(actor, account_id)

      { actor_kind: actor_kind, actor_type: actor_type, actor_id: actor.id }
    end

    def actor_in_account?(actor, account_id)
      return AccountUser.exists?(account_id: account_id, user_id: actor.id) if actor.is_a?(User)

      actor.respond_to?(:account_id) && actor.account_id == account_id
    end

    def reliable_since_for(membership, action, occurred_at)
      return occurred_at if action == 'add'

      where(
        account_id: membership.account_id,
        communication_thread_id: membership.communication_thread_id,
        participant_id: membership.user_id,
        action: 'add'
      ).order(occurred_at: :desc, id: :desc).pick(:reliable_since)
    end
  end

  def readonly?
    persisted?
  end

  private

  def thread_belongs_to_account
    return if communication_thread.blank? || account_id.blank? || communication_thread.account_id == account_id

    errors.add(:communication_thread, 'must belong to the same account')
  end

  def participant_belongs_to_account
    return if participant_id.blank? || account_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: participant_id)

    errors.add(:participant_id, 'must identify a workspace member in the same account')
  end

  def actor_identity_is_consistent
    expected_types = ACTOR_TYPES_BY_KIND.fetch(actor_kind, [])
    errors.add(:actor_type, 'does not match actor kind') unless expected_types.include?(actor_type)
    errors.add(:actor_id, 'must be blank for a system actor') if actor_kind == 'system' && actor_id.present?
    errors.add(:actor_id, 'must be present for a non-system actor') if actor_kind != 'system' && actor_id.blank?
  end

  def reliable_boundary_is_consistent
    return if reliable_since.blank? || occurred_at.blank? || reliable_since <= occurred_at

    errors.add(:reliable_since, 'must not be after occurred_at')
  end

  def immutable_fact
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Participant lifecycle fact is immutable: #{changed.join(', ')}") if changed.any?
  end
end
