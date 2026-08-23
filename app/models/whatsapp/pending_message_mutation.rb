class Whatsapp::PendingMessageMutation < ApplicationRecord
  self.table_name = 'whatsapp_pending_message_mutations'

  MUTATION_TYPES = %w[reaction edit revoke].freeze
  STATUSES = %w[pending invalid exhausted].freeze
  PENDING_TTL = 7.days
  RECONCILIATION_CLAIM_TTL = 10.minutes
  EXHAUSTED_PAYLOAD_RETENTION = 24.hours

  belongs_to :account
  belongs_to :inbox

  validates :event_id, :target_source_id, :mutation_type, presence: true
  validates :mutation_type, inclusion: { in: MUTATION_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validate :inbox_belongs_to_account

  scope :pending, -> { where(status: 'pending') }
  scope :due_for_reconciliation, lambda {
    pending.where('next_reconciliation_at IS NULL OR next_reconciliation_at <= ?', Time.current)
  }
  scope :due_for_payload_scrub, lambda {
    where(status: 'exhausted', payload_scrubbed_at: nil)
      .where(terminal_at: ..EXHAUSTED_PAYLOAD_RETENTION.ago)
  }

  def pending?
    status == 'pending'
  end

  def exhausted?
    status == 'exhausted'
  end

  def expires_at
    created_at + PENDING_TTL
  end

  def expired?
    expires_at <= Time.current
  end

  def record_attempt!
    update!(attempt_count: attempt_count + 1, last_attempted_at: Time.current)
  end

  def claim_reconciliation!
    with_lock do
      next if !pending? || next_reconciliation_at&.future?

      token = SecureRandom.uuid
      update!(
        reconciliation_token: token,
        next_reconciliation_at: RECONCILIATION_CLAIM_TTL.from_now
      )
      token
    end
  end

  def reconciliation_claim_owned?(token)
    with_lock { pending? && token.present? && reconciliation_token == token }
  end

  def schedule_reconciliation_at!(run_at, claim_token: nil)
    with_lock do
      next false unless pending?
      next false if claim_token.present? && reconciliation_token != claim_token

      update!(next_reconciliation_at: run_at, reconciliation_token: nil)
      true
    end
  end

  def release_reconciliation_claim!(token)
    with_lock do
      next false unless pending? && token.present? && reconciliation_token == token

      update!(next_reconciliation_at: nil, reconciliation_token: nil)
      true
    end
  end

  def mark_invalid!
    update!(
      status: 'invalid', terminal_reason: 'invalid_payload', terminal_at: Time.current,
      next_reconciliation_at: nil, reconciliation_token: nil, payload: {}, payload_scrubbed_at: Time.current
    )
  end

  def mark_exhausted!
    update!(
      status: 'exhausted', terminal_reason: 'target_not_found_before_expiry', terminal_at: Time.current,
      next_reconciliation_at: nil, reconciliation_token: nil
    )
  end

  def reactivate_exhausted_payload!
    with_lock do
      next false unless exhausted_payload_replayable?

      update!(status: 'pending', terminal_reason: nil, terminal_at: nil)
      true
    end
  end

  def exhausted_payload_replayable?(now: Time.current)
    exhausted? && payload_scrubbed_at.nil? && terminal_at.present? && terminal_at > now - EXHAUSTED_PAYLOAD_RETENTION
  end

  def scrub_exhausted_payload!
    with_lock do
      retention_expired = terminal_at.present? && terminal_at <= EXHAUSTED_PAYLOAD_RETENTION.ago
      next false unless exhausted? && payload_scrubbed_at.nil? && retention_expired

      update!(payload: {}, payload_scrubbed_at: Time.current)
      true
    end
  end

  private

  def inbox_belongs_to_account
    return if inbox.blank? || account_id == inbox.account_id

    errors.add(:inbox, 'must belong to the same account')
  end
end
