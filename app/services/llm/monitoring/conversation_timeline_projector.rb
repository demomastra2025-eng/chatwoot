# frozen_string_literal: true

require 'digest'

class Llm::Monitoring::ConversationTimelineProjector
  EVENT_NAME = 'llm.tool.complete'
  FEATURE = 'assistant'
  RUNTIME_MODE = 'captain_runtime'
  SOURCE_PREFIX = 'captain-tool'

  def initialize(event)
    @event = event
  end

  def call
    return unless projectable?
    return existing_message if existing_message.present?

    conversation.messages.create!(message_attributes)
  rescue ActiveRecord::RecordNotUnique
    existing_message
  end

  private

  attr_reader :event

  def projectable?
    event.event_name == EVENT_NAME &&
      event.feature == FEATURE &&
      event.runtime_mode == RUNTIME_MODE &&
      event.tool_name.present? &&
      conversation.present? &&
      event.account_id == conversation.account_id
  end

  def conversation
    @conversation ||= event.conversation
  end

  def existing_message
    @existing_message ||= conversation&.messages&.find_by(source_id: source_id)
  end

  def message_attributes
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content_type: :text,
      private: false,
      content: activity_content,
      source_id: source_id,
      created_at: event.created_at,
      content_attributes: {
        data: {
          type: 'captain_tool_event',
          event: outcome,
          llm_event_id: event.id,
          request_id: event.request_id,
          tool_name: event.tool_name
        }.compact
      }
    }
  end

  def activity_content
    I18n.with_locale(conversation.account.locale.presence || I18n.default_locale) do
      I18n.t("conversations.activity.captain.tool_#{outcome}", tool_name: event.tool_name)
    end
  end

  def outcome
    failed? ? 'failed' : 'completed'
  end

  def failed?
    event.error? || event.tool_failure? || event.payload.to_h['result_success'] == false
  end

  def source_id
    @source_id ||= "#{SOURCE_PREFIX}:#{Digest::SHA256.hexdigest(source_identity.join(':'))}"
  end

  def source_identity
    [
      event.account_id,
      event.conversation_id,
      execution_reference,
      event.tool_name,
      *tool_timing_identity,
      event.duration_ms,
      fallback_time
    ]
  end

  def execution_reference
    event.request_id.presence || event.trace_id.presence || event.session_id.presence
  end

  def tool_timing_identity
    event.payload.to_h.values_at('started_at', 'completed_at')
  end

  def fallback_time
    return if event.payload.to_h['started_at'].present? || event.payload.to_h['completed_at'].present?

    event.created_at&.change(usec: 0)&.iso8601
  end
end
