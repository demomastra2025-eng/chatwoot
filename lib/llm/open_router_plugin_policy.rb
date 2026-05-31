# frozen_string_literal: true

class Llm::OpenRouterPluginPolicy
  DENIED_PLUGIN_IDS = %w[
    apply-patch apply_patch openrouter:apply-patch openrouter:apply_patch pareto pareto-router pareto_router
    web web-search web_search openrouter:web-search openrouter:web_search openrouter:web-fetch openrouter:web_fetch
  ].freeze

  RUNTIME_ALLOWLIST_KEYS = %w[
    openrouter_allowed_plugins allowed_openrouter_plugins openrouter_plugin_allowlist
  ].freeze

  class << self
    def filter(plugins:, runtime_preferences: nil, default_allowed_ids: [])
      allowed_ids = allowed_plugin_ids(
        runtime_preferences: runtime_preferences,
        default_allowed_ids: default_allowed_ids
      )

      filtered = Array(plugins).filter_map do |plugin|
        id = plugin_id(plugin)
        normalized_id = normalize_plugin_id(id)
        next if normalized_id.blank? || denied?(normalized_id)
        next unless allowed_ids.include?(normalized_id)

        normalize_plugin(plugin, normalized_id)
      end

      filtered.uniq { |plugin| plugin_id(plugin).to_s }
    end

    def allowed_plugin_ids(runtime_preferences: nil, default_allowed_ids: [])
      (normalize_ids(default_allowed_ids) + runtime_allowed_plugin_ids(runtime_preferences)).uniq - DENIED_PLUGIN_IDS
    end

    def runtime_allowed_plugin_ids(runtime_preferences)
      preferences = normalize_preferences(runtime_preferences)
      RUNTIME_ALLOWLIST_KEYS.flat_map { |key| normalize_ids(preferences[key]) }.uniq
    end

    private

    def normalize_preferences(runtime_preferences)
      return {} unless runtime_preferences.respond_to?(:to_h)

      runtime_preferences.to_h.deep_stringify_keys
    rescue StandardError
      {}
    end

    def normalize_ids(value)
      Array(value).filter_map { |entry| normalize_plugin_id(entry).presence }.uniq
    end

    def plugin_id(plugin)
      return plugin if plugin.is_a?(String) || plugin.is_a?(Symbol)
      return plugin[:id] || plugin['id'] if plugin.respond_to?(:[])

      plugin
    rescue StandardError
      nil
    end

    def normalize_plugin_id(value)
      value.to_s.strip.tr('_', '-').presence
    end

    def denied?(plugin_id)
      DENIED_PLUGIN_IDS.include?(plugin_id)
    end

    def normalize_plugin(plugin, plugin_id)
      return { id: plugin_id } unless plugin.respond_to?(:to_h)

      plugin.to_h.deep_symbolize_keys.merge(id: plugin_id)
    rescue StandardError
      { id: plugin_id }
    end
  end
end
