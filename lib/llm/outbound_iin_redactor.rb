# frozen_string_literal: true

require_relative 'iin_token_vault'
require_relative 'pii_session_pseudonymizer'
require_relative 'egress_guard'

module Llm; end

# Server-side pre-LLM redaction gateway guaranteeing that Kazakhstan 12-digit personal IINs
# and session-scoped patient PII (FIO + phone numbers) never leave OneLink to external LLM providers
# (chat completions, tool results, decisions, embeddings, rerank, moderation or transcription prompts).
module Llm::OutboundIinRedactor
  SCALAR_SKIP_KEYS = %w[
    id tool_call_id call_id model file_data
    signature thought_signature input_audio format mime_type media_type
  ].to_set.freeze
  SCHEMA_SKIP_KEYS = %w[tools tool_choice response_format].to_set.freeze
  SENSITIVE_HASH_KEY_PATTERN = /\A(?:(?:medelement_)?iin|client_identifier|иин|жсн)\z/i
  SENSITIVE_PHONE_KEY_PATTERN = /\A(?:phone|phone_number|client_phone|caller_number|from_number|to_number)\z/i

  module RubyLlmConnectionPatch
    def post(url, payload, &)
      Llm::EgressGuard.check!
      super(url, Llm::OutboundIinRedactor.redact_payload(payload), &)
    end

    private

    def setup_middleware(faraday)
      # RubyLLM installs its retry middleware first. This inner middleware runs
      # for every adapter attempt, including retries inside a single #post.
      faraday.use Llm::EgressGuard::Middleware
      super
    end
  end

  module_function

  def redact_text(text)
    after_iin = Scheduling::IinValidator.tokenize_or_redact_text(text)
    Llm::PiiSessionPseudonymizer.active? ? Llm::PiiSessionPseudonymizer.mask_text(after_iin) : after_iin
  end

  def redact_iin_only(value)
    case value
    when String then Scheduling::IinValidator.tokenize_or_redact_text(value)
    when Array then value.map { |item| redact_iin_only(item) }
    when Hash then value.transform_values { |item| redact_iin_only(item) }
    else value
    end
  end

  def redact_payload(value)
    case value
    when String then redact_text(value)
    when Array then value.map { |item| redact_payload(item) }
    when Hash then redact_hash(value)
    else value
    end
  end

  def redact_hash(hash)
    binary_media = binary_media_hash?(hash)
    func_call = function_call_hash?(hash)
    hash.each_with_object({}) do |(key, item), copy|
      copy[key] = redact_hash_entry(key, item, binary_media: binary_media, func_call: func_call)
    end
  end

  def redact_hash_entry(key, item, binary_media: false, func_call: false)
    key_str = key.to_s
    return item if SCHEMA_SKIP_KEYS.include?(key_str) || (func_call && key_str == 'name')
    return item if skip_entry?(key_str, item, binary_media)

    replacement = sensitive_scalar_replacement(key_str, item)
    return replacement unless replacement.nil?

    redact_payload(item)
  end

  def sensitive_scalar_replacement(key_str, item)
    if sensitive_iin_entry?(key_str, item)
      return Llm::IinTokenVault.active? ? Llm::IinTokenVault.tokenize(item) : Scheduling::IinValidator::REDACTED_PLACEHOLDER
    end

    Llm::PiiSessionPseudonymizer.tokenize_phone(item.to_s) if sensitive_phone_entry?(key_str, item)
  end

  def skip_entry?(key_str, item, binary_media)
    return false if item.is_a?(Hash) || item.is_a?(Array)

    SCALAR_SKIP_KEYS.include?(key_str) || (binary_media && key_str == 'data' && item.is_a?(String))
  end

  def function_call_hash?(hash)
    keys = hash.keys.map(&:to_s)
    keys.include?('name') && keys.include?('arguments')
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

  def sensitive_phone_entry?(key_str, item)
    Llm::PiiSessionPseudonymizer.active? &&
      key_str.strip.match?(SENSITIVE_PHONE_KEY_PATTERN) &&
      Llm::PiiSessionPseudonymizer.phone_like_value?(item)
  end

  def install!
    return unless defined?(RubyLLM::Connection)
    return if RubyLLM::Connection <= RubyLlmConnectionPatch

    RubyLLM::Connection.prepend(RubyLlmConnectionPatch)
  end
  private_class_method :redact_hash, :redact_hash_entry, :skip_entry?, :function_call_hash?,
                       :binary_media_hash?, :sensitive_iin_entry?, :sensitive_phone_entry?
end

Llm::OutboundIinRedactor.install!
