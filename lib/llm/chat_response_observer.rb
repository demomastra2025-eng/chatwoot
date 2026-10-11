# frozen_string_literal: true

require 'securerandom'

class Llm::ChatResponseObserver
  OBSERVER_IVAR = :@onelink_chat_response_observer
  RESPONSE_ACCOUNTING_IVAR = :@onelink_provider_response_accounting
  SCOPE_STATE_KEY = :llm_chat_response_observer_scopes
  NON_CRITICAL_ERRORS = [StandardError, SystemStackError].freeze
  USAGE_KEYS = %w[
    prompt_tokens input_tokens completion_tokens output_tokens thinking_tokens reasoning_tokens
    total_tokens cached_tokens cache_creation_tokens estimated_cost cost openrouter_generation_id openrouter_generation
  ].freeze

  Scope = Struct.new(:payload, :response_count, :error_count, :seen_messages, :request_id, keyword_init: true) do
    def annotate_outer!(event_payload)
      self.request_id = event_payload['request_id']
      event_payload.except!(*Llm::ChatResponseObserver::USAGE_KEYS)
      event_payload['usage_scope'] = 'outer_request'
      event_payload['provider_response_count'] = response_count
      event_payload['provider_observability_error_count'] = error_count if error_count.positive?
    end
  end

  class << self
    def response_accounting(response)
      response.instance_variable_get(RESPONSE_ACCOUNTING_IVAR) if response
    end

    def active?(chat)
      observer = chat.instance_variable_get(OBSERVER_IVAR)
      observer && ActiveSupport::IsolatedExecutionState[SCOPE_STATE_KEY]&.key?(observer)
    end

    def observe(chat, payload)
      observer = for_chat(chat)
      return yield(nil) unless observer

      observer.with_scope(payload) { |scope| yield(scope) }
    end

    def log_failure(error)
      Rails.logger.warn("[Llm::ChatResponseObserver] suppressed observability failure class=#{error.class.name}")
    rescue StandardError
      nil
    end

    private

    def for_chat(chat)
      return unless chat.is_a?(RubyLLM::Chat) && chat.respond_to?(:after_message)

      chat.instance_variable_get(OBSERVER_IVAR) || new.tap do |observer|
        chat.after_message { |message| observer.record_message(message) }
        chat.instance_variable_set(OBSERVER_IVAR, observer)
      end
    rescue *NON_CRITICAL_ERRORS => e
      log_failure(e)
      nil
    end
  end

  def with_scope(payload)
    scopes = ActiveSupport::IsolatedExecutionState[SCOPE_STATE_KEY] ||= {}.compare_by_identity
    previous = scopes[self]
    scope = Scope.new(payload: payload.to_h.stringify_keys, response_count: 0, error_count: 0, seen_messages: Set.new)
    scopes[self] = scope
    response = yield(scope)
    mark_response_accounting(response, scope)
    response
  ensure
    if scopes
      if previous
        previous.response_count += scope.response_count if scope
        previous.error_count += scope.error_count if scope
        scopes[self] = previous
      else
        scopes.delete(self)
      end
      ActiveSupport::IsolatedExecutionState[SCOPE_STATE_KEY] = nil if scopes.empty?
    end
  end

  def record_message(message)
    scope = ActiveSupport::IsolatedExecutionState[SCOPE_STATE_KEY]&.[](self)
    return unless scope && message.respond_to?(:role) && message.role.to_s == 'assistant'
    return unless scope.seen_messages.add?(message)

    scope.response_count += 1
    payload = scope.payload.merge(
      'request_id' => SecureRandom.uuid,
      'parent_request_id' => Llm::EventBus.request_id,
      'usage_scope' => 'provider_response'
    )
    Llm::EventBus.publish('chat.complete', payload) do |event_payload|
      attach_response(event_payload, message, scope)
    end
  rescue *NON_CRITICAL_ERRORS => e
    scope.error_count += 1 if scope
    self.class.log_failure(e)
    nil
  end

  private

  def mark_response_accounting(response, scope)
    return if scope.response_count.zero? || response.nil?

    accounting = { request_id: scope.request_id, provider_response_count: scope.response_count }.freeze
    response.instance_variable_set(RESPONSE_ACCOUNTING_IVAR, accounting)
  rescue *NON_CRITICAL_ERRORS => e
    self.class.log_failure(e)
  end

  def attach_response(payload, message, scope)
    Llm::ObservabilityPayload.attach_provider_chat_response!(payload, message)
  rescue *NON_CRITICAL_ERRORS => e
    scope.error_count += 1
    payload['status'] = 'success'
    payload['error'] = false
    payload['observability_error_class'] = e.class.name
    self.class.log_failure(e)
  end
end
