class CommunicationThreadManualCallOccurrence < ApplicationRecord
  SOURCE_KINDS = %w[telephony_call_session].freeze
  IMMUTABLE_ATTRIBUTES = column_names.freeze

  belongs_to :account
  belongs_to :communication_thread

  validates :actor_type, inclusion: { in: ['User'] }
  validates :actor_id, :actor_name, :source_id, :source_ref, :occurred_at, :reliable_since, presence: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :schema_version, numericality: { only_integer: true, equal_to: 1 }
  validate :thread_belongs_to_account
  validate :actor_belongs_to_account
  validate :source_is_exact_manual_call
  validate :reliable_boundary_is_consistent
  validate :immutable_occurrence, on: :update

  class << self
    def record!(account:, communication_thread:, actor:, call_session:)
      attributes = occurrence_attributes(
        account: account,
        communication_thread: communication_thread,
        actor: actor,
        call_session: call_session
      )
      identity = attributes.slice(:account_id, :source_kind, :source_id)
      existing = find_by(identity)
      return verify_identity!(existing, attributes) if existing

      occurrence = create_or_find_by!(
        identity
      ) { |row| row.assign_attributes(attributes.except(:account_id, :source_kind, :source_id)) }
      verify_identity!(occurrence, attributes)
      occurrence
    end

    private

    def occurrence_attributes(account:, communication_thread:, actor:, call_session:)
      occurred_at = call_session.started_at || call_session.created_at
      {
        account_id: account.id,
        communication_thread_id: communication_thread.id,
        actor_type: 'User',
        actor_id: actor.id,
        actor_name: actor.name,
        source_kind: 'telephony_call_session',
        source_id: call_session.id,
        source_ref: call_session.external_call_ref,
        occurred_at: occurred_at,
        reliable_since: occurred_at,
        schema_version: 1,
        created_at: Time.current
      }
    end

    def verify_identity!(occurrence, attributes)
      expected = attributes.stringify_keys.except('created_at')
      actual = occurrence.attributes.slice(*expected.keys)
      return occurrence if actual == expected

      raise ActiveRecord::RecordNotUnique, 'manual call occurrence source identity collision'
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

  def actor_belongs_to_account
    return if actor_id.blank? || account_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: actor_id)

    errors.add(:actor_id, 'must identify a workspace member in the same account')
  end

  def source_is_exact_manual_call
    return if source_kind.blank? || source_id.blank? || account_id.blank?
    return if exact_call_session.present?

    errors.add(:source_id, 'must identify an outbound call session in the same account')
  end

  def exact_call_session
    Telephony::CallSession
      .where(
        id: source_id,
        account_id: account_id,
        external_call_ref: source_ref,
        direction: 'outbound'
      )
      .where("metadata -> 'metadata' ->> 'source' = 'onelink_browser_janus_sip'")
      .where("metadata -> 'metadata' ->> 'route_action' = 'operator'")
      .where("metadata -> 'metadata' ->> 'chatwoot_user_id' = ?", actor_id.to_s)
      .where("NOT (metadata ? 'ai_voice')")
      .where("NOT (metadata -> 'metadata' ? 'ai_voice')")
      .first
  end

  def reliable_boundary_is_consistent
    return if reliable_since.blank? || occurred_at.blank? || reliable_since <= occurred_at

    errors.add(:reliable_since, 'must not be after occurred_at')
  end

  def immutable_occurrence
    changed = IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "Manual call occurrence is immutable: #{changed.join(', ')}") if changed.any?
  end
end
