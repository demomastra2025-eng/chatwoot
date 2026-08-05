# frozen_string_literal: true

class Confirmations::CreateService
  # rubocop:disable Metrics/ParameterLists
  def initialize(
    account:, title:, body:, conversation: nil, contact: nil, inbox: nil,
    subject: nil, reminder: nil, expires_at: nil, requester: nil, metadata: {}, idempotency_key: nil
  )
    @account = account
    @title = title
    @body = body
    @conversation = conversation
    @contact = contact
    @inbox = inbox
    @subject = subject
    @reminder = reminder
    @expires_at = expires_at
    @requester = requester
    @metadata = metadata || {}
    @idempotency_key = idempotency_key.to_s.presence
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    return existing_request if existing_request.present?

    validate_context_records!
    ConfirmationRequest.create!(confirmation_attributes)
  end

  private

  attr_reader :account, :title, :body, :conversation, :contact, :inbox, :subject,
              :reminder, :expires_at, :requester, :metadata, :idempotency_key

  def existing_request
    return nil if idempotency_key.blank?

    @existing_request ||= ConfirmationRequest.find_by(account: account, idempotency_key: idempotency_key)
  end

  def validate_context_records!
    {
      conversation: conversation,
      contact: contact,
      inbox: inbox,
      requester: requester,
      subject: subject,
      reminder: reminder
    }.each do |name, record|
      validate_account_record!(record, name)
    end
  end

  def confirmation_attributes
    {
      account: account,
      conversation: conversation,
      contact: contact || conversation&.contact,
      inbox: inbox || conversation&.inbox,
      subject: subject,
      reminder: reminder,
      title: title,
      body: body,
      expires_at: expires_at,
      requested_by: requester,
      metadata: metadata.to_h.as_json,
      idempotency_key: idempotency_key
    }
  end

  def validate_account_record!(record, name)
    return if record.blank?
    return if record_belongs_to_account?(record)

    raise ArgumentError, "#{name} must belong to the current account"
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)
    return record.account_id == account.id if record.respond_to?(:account_id)

    false
  end
end
