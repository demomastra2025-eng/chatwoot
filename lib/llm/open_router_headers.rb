# frozen_string_literal: true

class Llm::OpenRouterHeaders
  DEFAULT_APP_URL = 'https://one-link.kz'
  DEFAULT_APP_TITLE = 'OneLink'
  DEFAULT_APP_CATEGORIES = 'personal-agent,general-chat'
  DEFAULT_CACHE_TTL_SECONDS = 300
  STATIC_CONTEXT_CACHE_TTL_SECONDS = 3600
  MAX_CACHE_TTL_SECONDS = 86_400
  CACHEABLE_POLICIES = %w[read_only static_context].freeze
  CACHEABLE_ENDPOINTS = [nil, '/chat/completions', '/embeddings'].freeze

  Result = Struct.new(:headers, :metadata, keyword_init: true)

  class << self
    def build(
      cache_policy: nil,
      provider_params: nil,
      native_endpoint: nil,
      cache_options: nil,
      include_cache: true,
      privacy_profile: nil,
      trace_capture_allowed: nil
    )
      cache = if include_cache
                response_cache(cache_policy, provider_params, native_endpoint, cache_options, privacy_profile, trace_capture_allowed)
              else
                disabled_cache('not_requested')
              end
      Result.new(
        headers: attribution_headers.merge(cache.headers),
        metadata: attribution_metadata.merge(cache.metadata)
      )
    end

    def attribution_headers
      {
        'HTTP-Referer' => app_url,
        'X-OpenRouter-Title' => app_title,
        'X-OpenRouter-Categories' => app_categories
      }.compact_blank
    end

    def apply!(request, headers: nil)
      normalize_headers(headers).merge(attribution_headers).each do |key, value|
        request[key.to_s] = value.to_s if value.present? || value == false
      end
      request
    end

    private

    def attribution_metadata
      {
        openrouter_attribution: 'enabled',
        openrouter_app_referer: app_url,
        openrouter_app_title: app_title
      }
    end

    def response_cache(cache_policy, provider_params, native_endpoint, cache_options, privacy_profile, trace_capture_allowed)
      options = normalize_cache_options(cache_options)
      policy = cache_policy.to_s.presence || 'disabled'
      return disabled_cache('runtime_disabled') if boolean_value(options[:enabled]) == false
      return disabled_cache('zdr_required') if provider_params.to_h.with_indifferent_access[:zdr] == true
      return disabled_cache('privacy_sensitive') if privacy_sensitive_cache?(privacy_profile, trace_capture_allowed)
      return disabled_cache('unsupported_endpoint') unless CACHEABLE_ENDPOINTS.include?(native_endpoint)

      return disabled_cache("policy_#{policy}") unless CACHEABLE_POLICIES.include?(policy)

      ttl = cache_ttl(options[:ttl], policy)
      headers = {
        'X-OpenRouter-Cache' => 'true',
        'X-OpenRouter-Cache-TTL' => ttl.to_s
      }
      headers['X-OpenRouter-Cache-Clear'] = 'true' if boolean_value(options[:clear]) == true

      Result.new(
        headers: headers,
        metadata: {
          openrouter_response_cache: 'enabled',
          openrouter_response_cache_ttl: ttl,
          openrouter_response_cache_clear: boolean_value(options[:clear]) == true
        }.compact
      )
    end

    def disabled_cache(reason)
      Result.new(
        headers: {},
        metadata: {
          openrouter_response_cache: 'disabled',
          openrouter_response_cache_reason: reason
        }
      )
    end

    def normalize_headers(headers)
      return {} unless headers.respond_to?(:to_h)

      headers.to_h.compact_blank
    rescue StandardError
      {}
    end

    def privacy_sensitive_cache?(privacy_profile, trace_capture_allowed)
      return true if privacy_profile.to_s == 'sensitive'

      boolean_value(trace_capture_allowed) == false
    end

    def normalize_cache_options(value)
      return {} unless value.respond_to?(:to_h)

      source = value.to_h.with_indifferent_access
      {
        enabled: first_present(source, :openrouter_response_cache, :response_cache, :cache_enabled),
        ttl: first_present(source, :openrouter_response_cache_ttl, :response_cache_ttl, :cache_ttl, :openrouter_cache_ttl),
        clear: first_present(source, :openrouter_response_cache_clear, :response_cache_clear, :cache_clear, :openrouter_cache_clear)
      }.compact
    rescue StandardError
      {}
    end

    def first_present(source, *keys)
      keys.each do |key|
        return source[key] if source.key?(key) && (source[key].present? || source[key] == false)
      end
      nil
    end

    def cache_ttl(value, policy)
      ttl = integer_value(value)
      ttl ||= policy.to_s == 'static_context' ? STATIC_CONTEXT_CACHE_TTL_SECONDS : DEFAULT_CACHE_TTL_SECONDS
      ttl.clamp(1, MAX_CACHE_TTL_SECONDS)
    end

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def boolean_value(value)
      return if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def app_url
      first_env(
        'OPENROUTER_HTTP_REFERER',
        'OPENROUTER_APP_URL',
        'FRONTEND_URL',
        'INSTALLATION_URL',
        'CHATWOOT_INSTALLATION_URL',
        'APP_URL'
      ) || DEFAULT_APP_URL
    end

    def app_title
      first_env('OPENROUTER_APP_TITLE', 'OPENROUTER_X_TITLE') || DEFAULT_APP_TITLE
    end

    def app_categories
      first_env('OPENROUTER_APP_CATEGORIES') || DEFAULT_APP_CATEGORIES
    end

    def first_env(*keys)
      keys.filter_map { |key| ENV[key].to_s.strip.presence }.first
    end
  end
end
