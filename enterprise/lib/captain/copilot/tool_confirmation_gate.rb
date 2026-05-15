# frozen_string_literal: true

require 'digest'

class Captain::Copilot::ToolConfirmationGate
  CONFIRMATION_PATTERN = /(?:\b(confirm|confirmed|approve|approved|yes|ok|okay|execute|send|run|do it)\b|(?:^|\s)(да|ок|окей|подтверждаю|подтвердил|согласен|согласна|выполняй|отправляй|запускай|делай)(?:\s|$|[.!?]))/i
  MAX_ARGUMENT_PREVIEW_LENGTH = 1000

  def initialize(copilot_thread:, tool_definition:, arguments:, user: nil)
    @copilot_thread = copilot_thread
    @tool_definition = (tool_definition || {}).with_indifferent_access
    @arguments = arguments || {}
    @user = user
  end

  def call
    return unless requires_confirmation?
    return if confirmed_pending_request?

    request = pending_request || create_pending_request

    Captain::ToolResult.success_output(
      message: 'Operator confirmation is required before executing this tool. Ask the operator to confirm the exact action, then call the tool again with the same arguments after confirmation.',
      data: {
        action: 'confirmation_required',
        confirmation_required: true,
        confirmation_request_id: request&.id,
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
    @copilot_thread.present? && ActiveModel::Type::Boolean.new.cast(@tool_definition[:requires_confirmation])
  end

  def confirmed_pending_request?
    request = pending_request
    return false if request.blank?

    latest_user_message = @copilot_thread.copilot_messages.user.where('id > ?', request.id).order(id: :desc).first
    return false unless confirmation_text?(latest_user_message&.message&.dig('content'))

    mark_request!(request, 'confirmed')
    true
  end

  def confirmation_text?(content)
    content.to_s.match?(CONFIRMATION_PATTERN)
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
    message['confirmation_gate']['confirmed_by_user_id'] = @user&.id
    message['confirmation_gate']['confirmed_at'] = Time.current.iso8601
    request.update!(message: message)
  end

  def arguments_digest
    @arguments_digest ||= Digest::SHA256.hexdigest(JSON.generate(canonical_value(@arguments)))
  end

  def arguments_preview
    @arguments_preview ||= JSON.generate(Captain::EncodingNormalizer.utf8(canonical_value(@arguments))).truncate(MAX_ARGUMENT_PREVIEW_LENGTH)
  rescue StandardError
    @arguments.to_s.truncate(MAX_ARGUMENT_PREVIEW_LENGTH)
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

  def tool_id
    @tool_definition[:id].presence || 'unknown_tool'
  end
end
