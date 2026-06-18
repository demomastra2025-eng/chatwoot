require 'digest'

class Whatsapp::FlowSession < ApplicationRecord
  self.table_name = 'whatsapp_flow_sessions'

  STATUSES = %w[pending sent submitted expired failed].freeze

  belongs_to :account
  belongs_to :inbox
  belongs_to :flow, class_name: 'Whatsapp::Flow', foreign_key: :whatsapp_flow_id, inverse_of: :flow_sessions
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true
  belongs_to :response_message, class_name: 'Message', optional: true

  before_validation :generate_token, on: :create
  before_validation :assign_token_metadata
  before_validation :assign_context_from_flow
  before_validation :assign_context_from_conversation
  before_validation :normalize_json_attributes

  validates :token_digest, :token_prefix, :status, presence: true
  validates :token_digest, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validate :associations_belong_to_account

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }

  def self.digest_token(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.prefix_token(token)
    token.to_s.first(8)
  end

  def self.find_by_token(token, account_id:, inbox_id:)
    return if token.blank?

    find_by(token_digest: digest_token(token), account_id: account_id, inbox_id: inbox_id)
  end

  def mark_sent!(message:, request_payload: {})
    update!(
      message: message,
      status: status == 'submitted' ? status : 'sent',
      sent_at: sent_at || Time.current,
      request_payload: request_payload.to_h,
      token: nil
    )
  end

  def mark_submitted!(message:, response_payload: {})
    update!(
      response_message: message,
      conversation: message.conversation,
      status: 'submitted',
      submitted_at: Time.current,
      response_payload: response_payload.to_h
    )
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def assign_token_metadata
    token_value = token.presence
    return if token_value.blank? && token_digest.present?

    self.token_digest = self.class.digest_token(token_value)
    self.token_prefix = self.class.prefix_token(token_value)
  end

  def assign_context_from_flow
    return if flow.blank?

    self.account ||= flow.account
    self.inbox ||= flow.inbox
  end

  def assign_context_from_conversation
    return if conversation.blank?

    self.account ||= conversation.account
    self.inbox ||= conversation.inbox
  end

  def normalize_json_attributes
    self.request_payload = request_payload.to_h if request_payload.blank? || request_payload.respond_to?(:to_h)
    self.response_payload = response_payload.to_h if response_payload.blank? || response_payload.respond_to?(:to_h)
    self.metadata = metadata.to_h if metadata.blank? || metadata.respond_to?(:to_h)
  end

  def associations_belong_to_account
    {
      inbox: inbox,
      flow: flow,
      conversation: conversation,
      message: message,
      response_message: response_message
    }.each do |name, record|
      next if record.blank?
      next if record.account_id == account_id && record_in_inbox?(record)

      errors.add(name, 'must belong to the current account and inbox')
    end
  end

  def record_in_inbox?(record)
    return true unless record.respond_to?(:inbox_id)

    record.inbox_id == inbox_id
  end
end
