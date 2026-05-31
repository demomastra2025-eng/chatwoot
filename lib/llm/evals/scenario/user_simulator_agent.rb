# frozen_string_literal: true

require 'json'

class Llm::Evals::Scenario::UserSimulatorAgent < Llm::Evals::Scenario::AgentAdapter
  SENSITIVE_KEY_PATTERN = /token|secret|password|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|credential|cookie/i

  def initialize(**attributes)
    super(role: :user, name: attributes.fetch(:name, 'ScenarioUserSimulator'))

    @description = attributes[:description].to_s
    @persona = attributes[:persona].to_s.presence
    @system_prompt = attributes[:system_prompt].to_s.presence
    @client = cached_client(attributes)
    @scripted_messages = Array(attributes[:scripted_messages]).map { |message| normalize_content(message) }
    @position = 0
  end

  def call(input)
    content, source = next_user_content(input)

    Llm::Evals::Scenario::AgentAdapter::Output.new(
      messages: [{ role: 'user', content: content }],
      events: [
        {
          action: 'user_simulator_message',
          name: 'scenario.user_simulator.message',
          simulator: name,
          source: source
        }
      ]
    )
  end

  private

  def next_user_content(input)
    scripted_content = next_scripted_content
    return [scripted_content, 'scripted'] if scripted_content.present?

    raise ArgumentError, 'scenario user simulator requires a client, cache replay, or scripted_messages' unless @client.callable?

    [client_content(input), 'client']
  end

  def next_scripted_content
    return if @position >= @scripted_messages.size

    @scripted_messages[@position].tap { @position += 1 }
  end

  def client_content(input)
    response = @client.call(simulator_request(input))
    normalize_response_content(response)
  end

  def simulator_request(input)
    {
      thread_id: input.thread_id,
      description: @description.presence,
      persona: @persona,
      system_prompt: effective_system_prompt,
      messages: reverse_roles(compact_messages(input.messages)),
      new_messages: reverse_roles(compact_messages(input.new_messages)),
      response_contract: {
        type: 'object',
        required: ['content'],
        properties: { content: { type: 'string' } }
      }
    }.compact
  end

  def effective_system_prompt
    return @system_prompt if @system_prompt.present?

    prompt = [
      'You are simulating a real user in an eval conversation.',
      'Write one short, natural user message that moves the scenario forward.',
      'Do not answer as the assistant. Do not explain the test. Return only the user message.'
    ]
    prompt << "Scenario: #{@description}" if @description.present?
    prompt << "Persona: #{@persona}" if @persona.present?
    prompt.join("\n")
  end

  def compact_messages(messages)
    Array(messages).map do |message|
      attributes = message.to_h.deep_symbolize_keys
      sanitize_value(attributes.slice(:role, :content, :reasoning, :_index).compact)
    end
  end

  def reverse_roles(messages)
    messages.map do |message|
      message.merge(role: reversed_role(message[:role]))
    end
  end

  def reversed_role(role)
    case role.to_s
    when 'user'
      'assistant'
    when 'assistant'
      'user'
    else
      role.to_s
    end
  end

  def normalize_response_content(response)
    case response
    when Hash
      attributes = response.deep_symbolize_keys
      normalize_content(attributes[:content] || attributes[:text] || attributes.dig(:message, :content))
    when String
      normalize_string_response(response)
    else
      normalize_content(response.respond_to?(:content) ? response.content : response.to_s)
    end
  end

  def normalize_string_response(response)
    return normalize_content(response) unless json_like?(response)

    attributes = JSON.parse(response).deep_symbolize_keys
    normalize_content(attributes[:content] || attributes[:text])
  rescue JSON::ParserError
    normalize_content(response)
  end

  def json_like?(value)
    value.to_s.strip.start_with?('{', '[')
  end

  def normalize_content(value)
    value.to_s.strip
  end

  def sanitize_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child_value), result|
        result[key] = sensitive_key?(key) ? '[REDACTED]' : sanitize_value(child_value)
      end
    when Array
      value.map { |child_value| sanitize_value(child_value) }
    when String
      redact_string(value)
    else
      value
    end
  end

  def sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEY_PATTERN)
  end

  def redact_string(value)
    value
      .gsub(/Bearer\s+[A-Za-z0-9._\-]+/, 'Bearer [REDACTED]')
      .gsub(/(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=([^\s&]+)/i, '\\1=[REDACTED]')
  end

  def cached_client(attributes)
    Llm::Evals::Scenario::CachedClient.new(
      client: attributes[:client],
      cache: attributes[:cache] || Llm::Evals::Scenario::ClientCache.new(
        cache_key: attributes[:cache_key],
        store: attributes[:cache_store],
        namespace: attributes.fetch(:cache_namespace, 'user_simulator'),
        mode: attributes.fetch(:cache_mode, :read_write)
      )
    )
  end
end
