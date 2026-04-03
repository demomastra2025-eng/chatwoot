class Captain::Tools::Copilot::BaseAccountTool < Captain::Tools::BaseTool
  MAX_RESULTS = 50

  private

  def account
    assistant.account
  end

  def current_conversation
    return nil unless @conversation

    account.conversations.find_by(id: @conversation.id)
  end

  def current_contact
    current_conversation&.contact
  end

  def current_company
    current_contact&.company
  end

  def current_deal
    return nil unless @conversation

    Captain::ContextFields.deal_for(account: account, conversation: @conversation)
  end

  def current_task
    return nil unless @conversation

    Captain::ContextFields.task_for(account: account, conversation: @conversation)
  end

  def current_appointment
    return nil unless @conversation

    Captain::ContextFields.appointment_for(account: account, conversation: @conversation)
  end

  def ensure_feature_enabled!(feature_name, message)
    raise ArgumentError, message unless account.feature_enabled?(feature_name)
  end

  def feature_enabled?(feature_name)
    account.feature_enabled?(feature_name)
  end

  def bootstrap_crm_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def formatted_record(record)
    return 'Record not found' if record.blank?
    return record.to_llm_text if record.respond_to?(:to_llm_text)

    JSON.pretty_generate(record.as_json)
  end

  def formatted_collection(records)
    return 'No records found' if records.blank?

    records.map { |record| formatted_record(record) }.join("\n---\n")
  end

  def formatted_payload(payload)
    JSON.pretty_generate(payload.as_json)
  end

  def cast_boolean(value, default: false)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def parse_json_hash(value, field_name:)
    return {} if value.blank?
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def parse_csv_ids(value)
    Array(value.to_s.split(',')).map(&:strip).reject(&:blank?)
  end

  def parse_datetime(value, field_name:, required: false)
    if value.blank?
      raise ArgumentError, "#{field_name} is required" if required

      return nil
    end

    parsed = Time.zone.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a valid datetime" if parsed.blank?

    parsed
  end
end
