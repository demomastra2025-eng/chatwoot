# frozen_string_literal: true

require 'openssl'

module Llm; end

# Reversible, tenant- and conversation-scoped server-side IIN tokenization vault.
# Replaces 12-digit IINs with [IIN_TOKEN_XXXXXXXXXX] before prompts/payloads leave OneLink,
# and resolves tokens back strictly inside the same (account_id, scope_id) for built-in tools.
# rubocop:disable Metrics/ModuleLength
module Llm::IinTokenVault
  THREAD_KEY = :llm_iin_token_vault_scope
  REDIS_KEY_PREFIX = 'iin_vault:v1'
  REDIS_TTL_SECONDS = 7.days.to_i
  TOKEN_PATTERN = /\[IIN_TOKEN_([0-9A-F]{10})\]/
  EXTERNAL_TOOL_CLASS_NAMES = %w[
    Captain::Tools::HttpTool
    Captain::Tools::CustomHttpTool
    Captain::Tools::Account::CustomHttpTool
    Captain::Tools::McpTool
    Captain::Tools::Account::McpTool
    Captain::Tools::SkillScriptTool
    Captain::Tools::Account::WebAccessBaseService
    Captain::Tools::Account::WebSearchService
    Captain::Tools::Account::WebScrapeUrlService
  ].freeze

  module_function

  def current_scope = Thread.current[THREAD_KEY]
  def active? = current_scope.present?

  def detokenizable_tool?(tool)
    return false if tool.nil?

    klass = tool.is_a?(Module) ? tool : tool.class
    klass.ancestors.none? { |anc| EXTERNAL_TOOL_CLASS_NAMES.include?(anc.name) }
  end

  def conversation_scope_id(conversation)
    conv_id = conversation&.try(:id).presence
    conv_id ? "conv:#{conv_id}" : nil
  end

  def voice_scope_id(call_session)
    return nil if call_session.blank?
    return "conv:#{call_session.conversation_id}" if call_session.try(:conversation_id).present?

    conv_scope = conversation_scope_id(call_session.try(:conversation))
    return conv_scope if conv_scope.present?

    call_session.try(:id).present? ? "call:#{call_session.id}" : nil
  end

  def with_scope(account_id:, scope_id:)
    return yield if account_id.blank? || scope_id.blank?

    previous = Thread.current[THREAD_KEY]
    return yield if same_scope?(previous, account_id, scope_id)

    Thread.current[THREAD_KEY] = { account_id: account_id.to_i, scope_id: scope_id.to_s, memory: {} }
    yield
  ensure
    Thread.current[THREAD_KEY] = previous if account_id.present? && scope_id.present?
  end

  def tokenize(raw_value)
    digits = Scheduling::IinValidator.normalize(raw_value)
    return Scheduling::IinValidator::REDACTED_PLACEHOLDER unless active? && digits&.match?(/\A\d{12}\z/)

    scope = current_scope
    s_key = scope_key(scope)
    token_id = hmac_token_id(s_key, digits)
    unless scope[:memory].key?(token_id)
      scope[:memory][token_id] = digits
      write_redis_entry(s_key, token_id, digits)
    end
    "[IIN_TOKEN_#{token_id}]"
  end

  def retokenize_known_digits(text)
    return text unless active? && text.is_a?(String) && current_scope[:memory].present?

    current_scope[:memory].each_with_object(text.dup) do |(token_id, digits), acc|
      acc.gsub!(/(?<!\d)#{Regexp.escape(digits)}(?!\d)/, "[IIN_TOKEN_#{token_id}]")
    end
  end

  def detokenize_text(text)
    return text unless active? && text.is_a?(String) && text.include?('[IIN_TOKEN_')

    scope = current_scope
    s_key = scope_key(scope)
    text.gsub(TOKEN_PATTERN) { |full| resolve_token(scope, s_key, Regexp.last_match(1)) || full }
  end

  def detokenize_deep(value)
    return value unless active?

    case value
    when String then detokenize_text(value)
    when Array then value.map { |item| detokenize_deep(item) }
    when Hash then value.transform_values { |item| detokenize_deep(item) }
    else value
    end
  end

  def strip_tokens(text, replacement = Scheduling::IinValidator::REDACTED_PLACEHOLDER)
    text.is_a?(String) && text.include?('[IIN_TOKEN_') ? text.gsub(TOKEN_PATTERN, replacement) : text
  end

  def same_scope?(previous, account_id, scope_id)
    previous.present? && previous[:account_id] == account_id.to_i && previous[:scope_id] == scope_id.to_s
  end

  def scope_key(scope) = "acct:#{scope[:account_id]}:#{scope[:scope_id]}"
  def hmac_token_id(s_key, digits) = OpenSSL::HMAC.hexdigest('SHA256', secret_material, "iin_token:#{s_key}:#{digits}")[0, 10].upcase
  def scope_digest(s_key) = OpenSSL::HMAC.hexdigest('SHA256', secret_material, "iin_scope:#{s_key}")[0, 24]
  def redis_key(s_key, token_id) = "#{REDIS_KEY_PREFIX}:#{scope_digest(s_key)}:#{token_id}"

  def secret_material
    key = Rails.application.secret_key_base.to_s
    return key if key.present?
    raise 'Rails.application.secret_key_base is required for Llm::IinTokenVault' if Rails.env.production?

    'onelink-nonprod-iin-token-vault-key'
  end

  def encryptor_for(s_key)
    key = OpenSSL::HMAC.digest('SHA256', secret_material, "iin_vault_enc:v1:#{s_key}")
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm')
  end

  def write_redis_entry(s_key, token_id, digits)
    return unless defined?(Redis::Alfred)

    encrypted = encryptor_for(s_key).encrypt_and_sign(digits, purpose: "#{s_key}:#{token_id}")
    Redis::Alfred.set(redis_key(s_key, token_id), encrypted, ex: REDIS_TTL_SECONDS)
  rescue StandardError
    nil
  end

  def resolve_token(scope, s_key, token_id)
    scope[:memory][token_id] || read_redis_entry(scope, s_key, token_id)
  end

  def read_redis_entry(scope, s_key, token_id)
    encrypted = defined?(Redis::Alfred) ? Redis::Alfred.get(redis_key(s_key, token_id)) : nil
    decrypted = encrypted.present? ? encryptor_for(s_key).decrypt_and_verify(encrypted, purpose: "#{s_key}:#{token_id}") : nil
    decrypted.is_a?(String) && decrypted.match?(/\A\d{12}\z/) ? (scope[:memory][token_id] = decrypted) : nil
  rescue StandardError
    nil
  end

  private_class_method :same_scope?, :scope_key, :secret_material, :hmac_token_id, :scope_digest,
                       :redis_key, :encryptor_for, :write_redis_entry, :resolve_token, :read_redis_entry
end
# rubocop:enable Metrics/ModuleLength
