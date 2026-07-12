class FieldReferences::RendererService
  FIELD_REFERENCE_REGEX = %r{\[([^\]]+)\]\(field://([^)]+)\)}
  RAW_BLOCK_REGEX = /({% raw %}.*?{% endraw %})/m
  CONTACT_STATE_ATTRIBUTES = %i[
    id name email phone_number identifier contact_type
    custom_attributes additional_attributes
  ].freeze
  CONVERSATION_STATE_ATTRIBUTES = %i[
    id display_id inbox_id contact_id status priority
    custom_attributes additional_attributes
  ].freeze
  INBOX_STATE_ATTRIBUTES = %i[id name].freeze
  ACCOUNT_STATE_ATTRIBUTES = %i[id name custom_attributes].freeze
  AGENT_STATE_ATTRIBUTES = %i[id name email available_name custom_attributes].freeze

  def initialize(message: nil, conversation: nil, contact: nil, inbox: nil, account: nil, sender: nil, appointment: nil)
    @message = message
    @conversation = conversation
    @contact = contact
    @inbox = inbox
    @account = account
    @sender = sender
    @appointment = appointment
  end

  def render(text)
    return text unless text.is_a?(String)
    return text if text.exclude?('(field://')

    return replace_field_references(text) unless text.include?('{% raw %}')

    text.split(RAW_BLOCK_REGEX).map do |segment|
      raw_block?(segment) ? segment : replace_field_references(segment)
    end.join
  end

  private

  attr_reader :message, :contact, :account, :appointment

  def conversation
    @conversation || message&.conversation
  end

  def inbox
    @inbox || message&.inbox || conversation&.inbox
  end

  def sender
    @sender || message&.sender
  end

  def resolve_field_reference(field_id)
    scope, path = normalize_field_id(field_id).split('.', 2)
    return '' if scope.blank? || path.blank?

    value = value_for(runtime_state[scope], path)
    format_value(value)
  end

  def runtime_state
    @runtime_state ||= {
      'contact' => contact_state,
      'conversation' => conversation_state,
      'inbox' => inbox_state,
      'account' => account_state,
      'agent' => agent_state,
      'deal' => deal_state,
      'task' => task_state,
      'appointment' => appointment_state
    }.compact
  end

  def contact_state
    contact = @contact || conversation&.contact
    return if contact.blank?

    contact.attributes.symbolize_keys.slice(*CONTACT_STATE_ATTRIBUTES)
  end

  def conversation_state
    return if conversation.blank?

    conversation.attributes.symbolize_keys.slice(*CONVERSATION_STATE_ATTRIBUTES).merge(
      display_id: conversation.display_id,
      label_list: conversation.label_list
    )
  end

  def inbox_state
    return if inbox.blank?

    inbox.attributes.symbolize_keys.slice(*INBOX_STATE_ATTRIBUTES)
  end

  def account_state
    account = @account || conversation&.account || inbox&.account
    return if account.blank?

    account.attributes.symbolize_keys.slice(*ACCOUNT_STATE_ATTRIBUTES)
  end

  def agent_state
    return if sender.blank?

    sender.attributes.symbolize_keys.slice(*AGENT_STATE_ATTRIBUTES)
  rescue NoMethodError
    nil
  end

  def deal_state
    return unless defined?(Captain::ContextFields)
    return if conversation.blank?
    return unless Captain::ContextFields.scope_visible_for_user?(
      scope: :deal,
      account: conversation.account,
      user: sender_user
    )

    Captain::ContextFields.deal_state_for(
      account: conversation.account,
      conversation: conversation
    )
  end

  def task_state
    return unless defined?(Captain::ContextFields)
    return if conversation.blank?
    return unless Captain::ContextFields.scope_visible_for_user?(
      scope: :task,
      account: conversation.account,
      user: sender_user
    )

    Captain::ContextFields.task_state_for(
      account: conversation.account,
      conversation: conversation
    )
  end

  def appointment_state
    return unless defined?(Captain::ContextFields)

    context_account = appointment_context_account
    return if context_account.blank?
    return unless Captain::ContextFields.scope_visible_for_user?(
      scope: :appointment,
      account: context_account,
      user: sender_user
    )

    Captain::ContextFields.appointment_state_for(
      account: context_account,
      conversation: conversation,
      appointment: appointment
    )
  end

  def appointment_context_account
    account || appointment&.account || conversation&.account
  end

  def value_for(state, path)
    return if state.blank? || path.blank?

    return value_from_custom_attributes(state, path.delete_prefix('custom_attributes.')) if path.start_with?('custom_attributes.')

    return value_from_custom_attributes(state, path.delete_prefix('custom_attribute.')) if path.start_with?('custom_attribute.')

    return value_from_additional_attributes(state, path.delete_prefix('additional_attributes.')) if path.start_with?('additional_attributes.')

    path.split('.').reduce(with_indifferent_access(state)) do |memo, key|
      break if memo.blank?

      fetch_value(memo, key)
    end
  end

  def value_from_custom_attributes(state, attribute_key)
    attributes = fetch_value(with_indifferent_access(state), 'custom_attributes')
    fetch_hash_value(attributes, attribute_key)
  end

  def value_from_additional_attributes(state, attribute_key)
    attributes = fetch_value(with_indifferent_access(state), 'additional_attributes')
    fetch_hash_value(attributes, attribute_key)
  end

  def fetch_hash_value(attributes, key)
    return if attributes.blank?

    with_indifferent_access(attributes)[key]
  end

  def fetch_value(container, key)
    if container.respond_to?(:key?)
      with_indifferent_access(container)[key]
    elsif container.respond_to?(key)
      container.public_send(key)
    end
  end

  def with_indifferent_access(value)
    value.is_a?(Hash) ? value.with_indifferent_access : value
  end

  def format_value(value)
    case value
    when nil
      ''
    when Array
      value.map { |item| utf8_string(item.to_s) }.join(', ')
    when Hash
      JSON.generate(utf8_value(value))
    when String
      utf8_string(value)
    else
      value.to_s
    end
  rescue JSON::GeneratorError
    utf8_string(value.to_s)
  end

  def utf8_value(value)
    return Captain::EncodingNormalizer.utf8(value) if defined?(Captain::EncodingNormalizer)

    case value
    when String
      utf8_string(value)
    when Array
      value.map { |item| utf8_value(item) }
    when Hash
      value.each_with_object({}) do |(key, item), memo|
        memo[key.is_a?(String) ? utf8_string(key) : key] = utf8_value(item)
      end
    else
      value
    end
  end

  def utf8_string(value)
    return Captain::EncodingNormalizer.string(value) if defined?(Captain::EncodingNormalizer)
    return value unless value.is_a?(String)

    candidate = value.dup
    candidate.force_encoding(Encoding::UTF_8) if candidate.encoding == Encoding::ASCII_8BIT
    return candidate if candidate.encoding == Encoding::UTF_8 && candidate.valid_encoding?

    candidate.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '�')
  end

  def normalize_field_id(field_id)
    field_id.to_s.gsub(/\\(.)/, '\1')
  end

  def sender_user
    sender if sender.is_a?(User)
  end

  def replace_field_references(text)
    text.gsub(FIELD_REFERENCE_REGEX) do
      resolve_field_reference(Regexp.last_match(2))
    end
  end

  def raw_block?(segment)
    segment.start_with?('{% raw %}') && segment.end_with?('{% endraw %}')
  end
end
