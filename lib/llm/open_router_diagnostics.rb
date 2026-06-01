# frozen_string_literal: true

class Llm::OpenRouterDiagnostics
  PROVIDER = Llm::OpenRouterModelCatalog::PROVIDER
  DEFAULT_SAMPLE_LIMIT = 8
  DEFAULT_RUNTIME_LOOKBACK = 24.hours
  DIAGNOSTIC_FEATURES = Llm::Models::OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS.keys.freeze
  COUNTED_CAPABILITIES = %w[
    tool_calling structured_output reasoning image_input audio_input file_input
    embedding moderation transcription rerank
  ].freeze

  class << self
    def call(account: nil, sample_limit: DEFAULT_SAMPLE_LIMIT, event_scope: LlmEvent.all, runtime_lookback: DEFAULT_RUNTIME_LOOKBACK)
      Llm::Config.with_runtime_cache do
        Llm::OpenRouterModelCatalog.with_model_configs_snapshot do
          Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot do
            new(account: account, sample_limit: sample_limit, event_scope: event_scope, runtime_lookback: runtime_lookback).call
          end
        end
      end
    end
  end

  def initialize(account: nil, sample_limit: DEFAULT_SAMPLE_LIMIT, event_scope: LlmEvent.all, runtime_lookback: DEFAULT_RUNTIME_LOOKBACK)
    @account = account
    @sample_limit = sample_limit.to_i.positive? ? sample_limit.to_i : DEFAULT_SAMPLE_LIMIT
    @event_scope = event_scope
    @runtime_lookback = runtime_lookback
    @model_configs = Llm::OpenRouterModelCatalog.model_configs
    @endpoint_configs = Llm::OpenRouterEndpointCatalog.endpoint_configs
  end

  def call
    {
      key_status: key_status,
      catalog: catalog_summary,
      endpoints: endpoint_summary,
      runtime: runtime_summary,
      usage: usage_summary,
      admin_operations: Llm::OpenRouterAdminOperations.call,
      workspace_policy: workspace_policy_summary,
      guardrails: guardrail_summary,
      features: feature_summaries,
      model_eligibility: sampled_model_eligibility
    }
  end

  private

  attr_reader :account, :sample_limit, :event_scope, :runtime_lookback, :model_configs, :endpoint_configs

  def key_status
    {
      provider: PROVIDER,
      effective_configured: Llm::Config.provider_available?(PROVIDER, account: account),
      account_configured: account.present? && Llm::Config.account_provider_available?(PROVIDER, account: account),
      global_configured: Llm::Config.installation_provider_available?(PROVIDER),
      custom_endpoint: Llm::Config.custom_api_base_configured?(PROVIDER, account: account),
      health: Llm::OpenRouterKeyHealth.metadata
    }
  end

  def catalog_summary
    metadata = Llm::OpenRouterModelCatalog.metadata
    {
      source: metadata[:source],
      using_fallback: metadata[:using_fallback],
      refresh_status: metadata[:refresh_status],
      last_started_at: metadata[:last_started_at],
      last_finished_at: metadata[:last_finished_at],
      last_refreshed_at: metadata[:last_refreshed_at],
      last_refresh_error: metadata[:last_refresh_error],
      last_refresh_diff: refresh_diff_summary(metadata[:last_refresh_diff]),
      total_models: metadata[:total_models] || model_configs.count,
      stale_models: metadata[:stale_models],
      disabled_models: metadata[:disabled_models],
      counts_by_type: counts_by_type,
      capability_counts: capability_counts
    }
  end

  def endpoint_summary
    metadata = Llm::OpenRouterEndpointCatalog.metadata
    {
      source: metadata[:source],
      total_models: metadata[:total_models] || endpoint_configs.count,
      total_endpoints: metadata[:total_endpoints] || endpoint_configs.values.sum { |config| Array(config['endpoints']).count },
      provider_count: metadata[:provider_count],
      providers: Array(metadata[:providers]),
      stale_endpoints: metadata[:stale_endpoints],
      pending_model_count: metadata[:pending_model_count],
      pending_model_ids: Array(metadata[:pending_model_ids]).first(10),
      provider_counts: endpoint_provider_counts,
      refresh_status: metadata[:refresh_status],
      last_started_at: metadata[:last_started_at],
      last_finished_at: metadata[:last_finished_at],
      last_refreshed_at: metadata[:last_refreshed_at],
      last_refresh_error: metadata[:last_refresh_error],
      last_refresh_diff: refresh_diff_summary(metadata[:last_refresh_diff]),
      sample_models: endpoint_samples
    }
  end

  def runtime_summary
    scoped = runtime_scope
    chat_events = scoped.chat_completions
    {
      provider: PROVIDER,
      window_started_at: runtime_window.begin,
      window_ended_at: runtime_window.end,
      total_events: scoped.count,
      request_count: chat_events.count,
      error_count: scoped.error_events.count,
      provider_failure_count: scoped.where(error_code: Llm::Monitoring::RuntimeHealth::PROVIDER_FAILURE_ERROR_CODES).count,
      blocked_count: scoped.blocked_events.count,
      tool_failure_count: scoped.tool_failure_events.count,
      schema_invalid_count: scoped.schema_invalid_events.count,
      total_tokens: scoped.sum(:total_tokens),
      estimated_cost: scoped.sum(:estimated_cost),
      avg_duration_ms: chat_events.average(:duration_ms)&.to_f,
      avg_queue_wait_ms: scoped.average(:queue_wait_ms)&.to_f,
      by_feature: top_counts(compact_counts(scoped.group(:feature).count)),
      by_model: top_counts(compact_counts(scoped.group(:model).count)),
      recent_error_codes: top_counts(compact_counts(scoped.error_events.group(:error_code).count)),
      last_event_at: scoped.maximum(:created_at)
    }
  end

  def usage_summary
    Llm::UsageLedger.summary(
      account: account,
      range: runtime_window,
      provider: PROVIDER
    )
  rescue StandardError => e
    {
      error: "#{e.class}: #{Llm::OpenRouterModelCatalog.sanitize_error_message(e)}"
    }
  end

  def workspace_policy_summary
    Llm::OpenRouterWorkspacePolicy.resolve(account: account).to_h
  rescue StandardError => e
    {
      error: "#{e.class}: #{Llm::OpenRouterModelCatalog.sanitize_error_message(e)}"
    }
  end

  def guardrail_summary
    feature_guardrails = DIAGNOSTIC_FEATURES.each_with_object({}) do |feature_key, result|
      result[feature_key] = feature_policy_for(feature_key).guardrails
    rescue StandardError => e
      result[feature_key] = {
        error: {
          status: 'diagnostics_failed',
          enforcement: "#{e.class}: #{Llm::OpenRouterModelCatalog.sanitize_error_message(e)}"
        }
      }
    end

    {
      workspace: workspace_policy_summary[:guardrails].to_h,
      features: feature_guardrails,
      status_counts: guardrail_status_counts(feature_guardrails)
    }
  end

  def feature_summaries
    DIAGNOSTIC_FEATURES.each_with_object({}) do |feature_key, result|
      feature_config = Llm::Models.feature_config(feature_key, account: account).to_h
      selected_model = Llm::Config.model_for(feature: feature_key, account: account)
      result[feature_key] = {
        selected_model: selected_model,
        default_model: feature_config[:default],
        configured_default: feature_config[:configured_default],
        required_capabilities: Array(feature_config[:required_capabilities]),
        available_model_count: Array(feature_config[:models]).size,
        policy: feature_policy_for(feature_key).to_h,
        selected_model_diagnostics: selected_model.present? ? eligibility_for(selected_model, feature_key) : nil
      }.compact
    rescue StandardError => e
      result[feature_key] = {
        error: "#{e.class}: #{Llm::OpenRouterModelCatalog.sanitize_error_message(e)}"
      }
    end
  end

  def feature_policy_for(feature_key)
    Llm::OpenRouterFeaturePolicy.for(feature: feature_key, account: account)
  end

  def guardrail_status_counts(feature_guardrails)
    feature_guardrails.values
                      .flat_map { |guardrails| guardrails.to_h.values }
                      .filter_map { |guardrail| guardrail.to_h[:status] || guardrail.to_h['status'] }
                      .tally
                      .sort_by { |status, count| [-count, status.to_s] }
                      .to_h
  end

  def sampled_model_eligibility
    sampled_model_ids.map do |model_id|
      model_config = model_configs[model_id].to_h
      endpoint_metadata = endpoint_configs[model_id].to_h
      {
        id: model_id,
        display_name: model_config['display_name'].presence || model_id,
        type: model_config['type'],
        capabilities: Array(model_config['capabilities']),
        endpoint_count: Array(endpoint_metadata['endpoints']).size,
        endpoint_providers: Array(endpoint_metadata['providers']),
        features: DIAGNOSTIC_FEATURES.index_with { |feature_key| eligibility_for(model_id, feature_key) }
      }
    end
  end

  def eligibility_for(model_id, feature_key)
    diagnostics = Llm::OpenRouterCapabilityResolver.call(
      model_id: model_id,
      feature: feature_key,
      account: account,
      runtime_filtered: false
    )
    reasons = Array(diagnostics.reasons)
    {
      allowed: diagnostics.allowed?,
      reason_codes: reasons.filter_map { |reason| reason[:code] || reason['code'] },
      reasons: reasons
    }
  end

  def sampled_model_ids
    (prioritized_sample_model_ids + capability_representative_model_ids + model_configs.keys.sort)
      .compact_blank
      .uniq
      .first(sample_limit)
  end

  def prioritized_sample_model_ids
    selected_or_default_model_ids = DIAGNOSTIC_FEATURES.flat_map do |feature_key|
      feature_config = Llm::Models.feature_config(feature_key, account: account).to_h
      [Llm::Config.model_for(feature: feature_key, account: account), feature_config[:default]]
    rescue StandardError
      []
    end

    selected_or_default_model_ids.select { |model_id| model_configs.key?(model_id) }
  end

  def capability_representative_model_ids
    COUNTED_CAPABILITIES.filter_map do |capability|
      model_configs.keys.sort.find do |model_id|
        Array(model_configs[model_id]['capabilities']).map(&:to_s).include?(capability)
      end
    end
  end

  def counts_by_type
    model_configs.values.each_with_object(Hash.new(0)) do |config, counts|
      counts[(config['type'].presence || 'unknown').to_sym] += 1
    end.to_h
  end

  def refresh_diff_summary(diff)
    diff = (diff || {}).to_h.deep_stringify_keys
    diff.each_with_object({}) do |(key, value), result|
      values = Array(value)
      result[key.to_sym] = {
        count: values.count,
        sample: values.first(sample_limit)
      }
    end
  end

  def capability_counts
    COUNTED_CAPABILITIES.each_with_object({}) do |capability, counts|
      count = model_configs.values.count { |config| Array(config['capabilities']).map(&:to_s).include?(capability) }
      counts[capability.to_sym] = count if count.positive?
    end
  end

  def endpoint_provider_counts
    endpoint_configs.values
                    .flat_map { |config| Array(config['endpoints']) }
                    .filter_map { |endpoint| endpoint['provider_name'].presence }
                    .tally
                    .sort_by { |provider, count| [-count, provider] }
                    .to_h
  end

  def endpoint_samples
    endpoint_configs.keys.sort.first(sample_limit).map do |model_id|
      config = endpoint_configs[model_id].to_h
      endpoints = Array(config['endpoints'])
      {
        model_id: model_id,
        endpoint_count: endpoints.count,
        providers: Array(config['providers']),
        zdr_endpoint_count: endpoints.count { |endpoint| ActiveModel::Type::Boolean.new.cast(endpoint['zdr']) },
        data_collection: endpoints.filter_map { |endpoint| endpoint['data_collection'].presence }.uniq.sort
      }
    end
  end

  def runtime_scope
    scoped = event_scope.where(provider: PROVIDER).for_date_range(runtime_window)
    account.present? ? scoped.for_account(account.id) : scoped
  end

  def runtime_window
    @runtime_window ||= begin
      ended_at = Time.current
      (ended_at - runtime_lookback)..ended_at
    end
  end

  def compact_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key] = value
    end
  end

  def top_counts(counts)
    counts.sort_by { |key, value| [-value.to_i, key.to_s] }
          .first(sample_limit)
          .to_h
  end
end
