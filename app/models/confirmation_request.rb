# frozen_string_literal: true

class ConfirmationRequest < ApplicationRecord
  STATUSES = %w[pending confirmed declined reschedule_requested expired].freeze
  RESOLUTION_SOURCES = %w[button link text ai manual system].freeze
  SUPPORTED_SUBJECT_TYPES = %w[Scheduling::Appointment Crm::Deal Crm::Task Conversation].freeze

  belongs_to :account
  belongs_to :conversation, optional: true
  belongs_to :contact, optional: true
  belongs_to :inbox, optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true
  belongs_to :resolved_message, class_name: 'Message', optional: true
  belongs_to :delivery_message, class_name: 'Message', optional: true
  belongs_to :subject, polymorphic: true, optional: true

  enum :status, STATUSES.index_with(&:itself)

  before_validation :generate_token, on: :create
  before_validation :assign_context_from_conversation
  before_validation :normalize_json_attributes

  validates :title, :body, :status, :token, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :resolution_source, inclusion: { in: RESOLUTION_SOURCES }, allow_blank: true
  validates :token, uniqueness: true
  validates :idempotency_key, uniqueness: { scope: :account_id }, allow_blank: true
  validates :subject_type, inclusion: { in: SUPPORTED_SUBJECT_TYPES }, allow_blank: true
  validate :associations_belong_to_account

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }
  scope :active_pending, -> { pending.where('expires_at IS NULL OR expires_at > ?', Time.current) }

  def past_due?
    pending? && expires_at.present? && expires_at <= Time.current
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def assign_context_from_conversation
    return if conversation.blank?

    self.contact ||= conversation.contact
    self.inbox ||= conversation.inbox
  end

  def normalize_json_attributes
    self.metadata = metadata.to_h if metadata.blank? || metadata.respond_to?(:to_h)
    self.resolution_metadata = resolution_metadata.to_h if resolution_metadata.blank? || resolution_metadata.respond_to?(:to_h)
  end

  def associations_belong_to_account
    {
      conversation: conversation,
      contact: contact,
      inbox: inbox,
      requested_by: requested_by,
      resolved_by: resolved_by,
      resolved_message: resolved_message,
      delivery_message: delivery_message,
      subject: subject
    }.each do |name, record|
      next if record.blank?
      next if record_belongs_to_account?(record)

      errors.add(name, 'must belong to the current account')
    end
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)
    return record.account_id == account_id if record.respond_to?(:account_id)

    false
  end
end
