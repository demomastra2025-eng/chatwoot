class Captain::Tools::Operations::BaseOperation
  def initialize(assistant:, conversation: nil, actor: nil)
    @assistant = assistant
    @conversation = conversation
    @actor = actor
  end

  private

  attr_reader :assistant, :conversation, :actor

  def account
    assistant.account
  end

  def current_contact
    conversation&.contact
  end

  def current_company
    current_contact&.company
  end

  def current_deal
    return nil unless conversation

    Captain::ContextFields.deal_for(account: account, conversation: conversation)
  end

  def current_task
    return nil unless conversation

    Captain::ContextFields.task_for(account: account, conversation: conversation)
  end

  def current_appointment
    return nil unless conversation

    Captain::ContextFields.appointment_for(account: account, conversation: conversation)
  end

  def ensure_feature_enabled!(feature_name, message)
    raise ArgumentError, message unless account.feature_enabled?(feature_name)
  end

  def bootstrap_crm_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def parsed_hash(value, field_name:)
    return {} if value.blank?
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def optional_positive_id(value)
    Captain::Tools::InputNormalizer.optional_positive_id(value)
  end

  def required_positive_id(value, field_name:)
    Captain::Tools::InputNormalizer.required_positive_id(value, field_name: field_name)
  end

  def with_idempotent_creation(tool_id, params)
    cached_record = Captain::ToolExecutionIdempotency.fetch_record(
      assistant: assistant,
      tool_id: tool_id,
      params: params,
      scope: idempotency_scope
    )
    return cached_record if cached_record.present?

    record = yield

    Captain::ToolExecutionIdempotency.store_record(
      assistant: assistant,
      tool_id: tool_id,
      params: params,
      scope: idempotency_scope,
      record: record
    )
  end

  def idempotency_scope
    {
      account_id: account.id,
      conversation_id: conversation&.id,
      actor_id: actor&.id,
      contact_id: current_contact&.id
    }.compact
  end
end
