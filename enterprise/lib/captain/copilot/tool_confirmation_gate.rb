# frozen_string_literal: true

require 'digest'

class Captain::Copilot::ToolConfirmationGate
  CONFIRMATION_PATTERN = /
    (?:\b(confirm|confirmed|approve|approved|execute|send|run|do\ it)\b|
    (?:^|\s)(да|подтверждаю|подтвердил|согласен|согласна|выполняй|отправляй|запускай|делай)(?:\s|$|[.!?]))
  /ix
  NEGATIVE_CONFIRMATION_PATTERN = /
    (?:\b(do\ not|don't|dont|no|cancel|stop|reject|deny)\b|
    (?:^|\s)(не|нет|отмена|отменить|стоп|стой|отклоняю)(?:\s|$|[.!?]))
  /ix
  CONFIRMATION_TTL = 30.minutes
  MAX_ARGUMENT_PREVIEW_LENGTH = 1000
  SENSITIVE_KEY_PATTERN = /(otp|token|secret|password|credential|authorization|process_?id|session|api_?key|access_?key|refresh)/i

  def initialize(copilot_thread:, tool_definition:, arguments:, user: nil)
    @copilot_thread = copilot_thread
    @tool_definition = (tool_definition || {}).with_indifferent_access
    @arguments = arguments || {}
    @user = user
  end

  def call
    return unless requires_confirmation?
    return missing_thread_result if @copilot_thread.blank?
    return if confirmed_pending_request?

    request = pending_request || create_pending_request

    Captain::ToolResult.success_output(
      message: confirmation_message(request),
      data: {
        action: 'confirmation_required',
        confirmation_required: true,
        confirmation_request_id: request&.id,
        confirmation_token: confirmation_token(request),
        tool_id: tool_id,
        tool_title: @tool_definition[:title],
        risk_level: @tool_definition[:risk_level],
        arguments_digest: arguments_digest,
        arguments_preview: arguments_preview
      }.compact
    )
  end

  private

  def requires_confirmation?
    ActiveModel::Type::Boolean.new.cast(@tool_definition[:requires_confirmation])
  end

  def missing_thread_result
    Captain::ToolResult.success_output(
      message: 'Operator confirmation is required, but no copilot thread is available to store the confirmation request. ' \
               'Retry from a copilot thread.',
      data: {
        action: 'confirmation_required',
        confirmation_required: true,
        confirmation_unavailable: true,
        tool_id: tool_id,
        tool_title: @tool_definition[:title],
        risk_level: @tool_definition[:risk_level],
        arguments_digest: arguments_digest,
        arguments_preview: arguments_preview
      }.compact
    )
  end

  def confirmed_pending_request?
    request = pending_request
    return false if request.blank?
    return false if confirmation_expired?(request)

    latest_user_message = @copilot_thread.copilot_messages.user.where('id > ?', request.id).order(id: :desc).first
    return false unless confirmation_text?(latest_user_message&.message&.dig('content'), request)

    mark_request!(request, 'confirmed')
    true
  end

  def confirmation_text?(content, request)
    text = content.to_s
    return false if text.blank?
    return false if text.match?(NEGATIVE_CONFIRMATION_PATTERN)
    return false unless text.match?(CONFIRMATION_PATTERN)

    text.include?(confirmation_token(request)) || text.include?(request.id.to_s) || text.include?(tool_id)
  end

  def pending_request
    @pending_request ||= @copilot_thread.copilot_messages.assistant_thinking.order(created_at: :desc, id: :desc).detect do |message|
      gate = message.message['confirmation_gate']
      gate.present? &&
        gate['status'] == 'pending' &&
        gate['tool_id'].to_s == tool_id &&
        gate['arguments_digest'].to_s == arguments_digest
    end
  end

  def create_pending_request
    @copilot_thread.copilot_messages.create!(
      message_type: 'assistant_thinking',
      message: {
        'content' => "Confirmation required for #{tool_id}",
        'function_name' => tool_id,
        'confirmation_gate' => {
          'status' => 'pending',
          'tool_id' => tool_id,
          'tool_title' => @tool_definition[:title],
          'risk_level' => @tool_definition[:risk_level],
          'arguments_digest' => arguments_digest,
          'arguments_preview' => arguments_preview,
          'confirmation_token' => confirmation_token_for_digest,
          'requested_by_user_id' => @user&.id,
          'requested_at' => Time.current.iso8601
        }.compact
      }
    )
  end

  def mark_request!(request, status)
    message = request.message.deep_dup
    message['confirmation_gate'] ||= {}
    message['confirmation_gate']['status'] = status
    message['confirmation_gate']['confirmed_by_user_id'] = @user&.id if status == 'confirmed'
    message['confirmation_gate']['confirmed_at'] = Time.current.iso8601 if status == 'confirmed'
    message['confirmation_gate']['expired_at'] = Time.current.iso8601 if status == 'expired'
    request.update!(message: message)
  end

  def confirmation_expired?(request)
    requested_at = Time.zone.parse(request.message.dig('confirmation_gate', 'requested_at').to_s)
    return false if requested_at.blank?
    return false if requested_at >= CONFIRMATION_TTL.ago

    mark_request!(request, 'expired')
    true
  rescue ArgumentError, TypeError
    false
  end

  def confirmation_message(request)
    'Operator confirmation is required before executing this tool. ' \
      "Ask the operator to confirm this exact action with confirmation token #{confirmation_token(request)}, " \
      'then call the tool again with the same arguments after confirmation.'
  end

  def arguments_digest
    @arguments_digest ||= Digest::SHA256.hexdigest(JSON.generate(canonical_value(@arguments)))
  end

  def arguments_preview
    redacted_arguments = redact_sensitive(canonical_value(@arguments))
    normalized_arguments = Captain::EncodingNormalizer.utf8(redacted_arguments)
    @arguments_preview ||= JSON.generate(normalized_arguments).truncate(MAX_ARGUMENT_PREVIEW_LENGTH)
  rescue StandardError
    @arguments.to_s.truncate(MAX_ARGUMENT_PREVIEW_LENGTH)
  end

  def confirmation_token(request)
    request.message.dig('confirmation_gate', 'confirmation_token').presence || confirmation_token_for_digest
  end

  def confirmation_token_for_digest
    @confirmation_token_for_digest ||= arguments_digest.first(12)
  end

  def canonical_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key.to_s] = canonical_value(item)
      end.sort.to_h
    when Array
      value.map { |item| canonical_value(item) }
    else
      value
    end
  end

  def redact_sensitive(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key] = sensitive_key?(key) ? '[FILTERED]' : redact_sensitive(item)
      end
    when Array
      value.map { |item| redact_sensitive(item) }
    else
      value
    end
  end

  def sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEY_PATTERN)
  end

  def tool_id
    @tool_definition[:id].presence || 'unknown_tool'
  end
end
