# frozen_string_literal: true

module Llm; end

# Server-side pre-LLM redaction gateway guaranteeing that Kazakhstan 12-digit personal IINs
# never leave OneLink to external LLM providers (chat completions, tool results, decisions,
# embeddings, rerank, moderation or transcription prompts).
module Llm::OutboundIinRedactor
  SCALAR_SKIP_KEYS = %w[
    id tool_call_id call_id model file_data
    signature thought_signature input_audio format mime_type media_type
  ].to_set.freeze
  SENSITIVE_HASH_KEY_PATTERN = /\A(?:(?:medelement_)?iin|client_identifier|иин|жсн)\z/i

  module RubyLlmConnectionPatch
    def post(url, payload, &)
      super(url, Llm::OutboundIinRedactor.redact_payload(payload), &)
    end
  end

  module_function

  def redact_text(text)
    Scheduling::IinValidator.redact_text(text)
  end

  def redact_payload(value)
    case value
    when String then Scheduling::IinValidator.redact_text(value)
    when Array then value.map { |item| redact_payload(item) }
    when Hash then redact_hash(value)
    else value
    end
  end

  def redact_hash(hash)
    binary_media = binary_media_hash?(hash)
    hash.each_with_object({}) do |(key, item), copy|
      copy[key] = redact_hash_entry(key, item, binary_media: binary_media)
    end
  end

  def redact_hash_entry(key, item, binary_media: false)
    key_str = key.to_s
    return item if skip_entry?(key_str, item, binary_media)
    return Scheduling::IinValidator::REDACTED_PLACEHOLDER if sensitive_iin_entry?(key_str, item)

    redact_payload(item)
  end

  def skip_entry?(key_str, item, binary_media)
    return false if item.is_a?(Hash) || item.is_a?(Array)

    SCALAR_SKIP_KEYS.include?(key_str) || (binary_media && key_str == 'data' && item.is_a?(String))
  end

  def binary_media_hash?(hash)
    keys = hash.keys.map(&:to_s)
    return true if keys.include?('mime_type') || keys.include?('media_type')

    (hash['type'] || hash[:type]).to_s == 'base64'
  end

  def sensitive_iin_entry?(key_str, item)
    key_str.strip.match?(SENSITIVE_HASH_KEY_PATTERN) &&
      (item.is_a?(String) || item.is_a?(Integer)) &&
      Scheduling::IinValidator.iin_like?(item)
  end

  def install!
    return unless defined?(RubyLLM::Connection)
    return if RubyLLM::Connection <= RubyLlmConnectionPatch

    RubyLLM::Connection.prepend(RubyLlmConnectionPatch)
  end
  private_class_method :redact_hash, :redact_hash_entry, :skip_entry?, :binary_media_hash?, :sensitive_iin_entry?
end

Llm::OutboundIinRedactor.install!
