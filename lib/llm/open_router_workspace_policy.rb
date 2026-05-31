# frozen_string_literal: true

class Llm::OpenRouterWorkspacePolicy
  DEFAULT_PRIVACY_PROFILE = 'standard'
  PRIVACY_PROFILES = {
    'standard' => {
      allow_fallbacks: true,
      data_collection: 'deny',
      zdr: false,
      trace_capture_allowed: true
    },
    'sensitive' => {
      allow_fallbacks: true,
      data_collection: 'deny',
      zdr: false,
      trace_capture_allowed: false
    },
    'zdr_required' => {
      allow_fallbacks: false,
      data_collection: 'deny',
      zdr: true,
      trace_capture_allowed: false
    }
  }.freeze

  Policy = Struct.new(:privacy_profile, :workspace, :provider_preferences, :guardrails, keyword_init: true) do
    def trace_capture_allowed?
      PRIVACY_PROFILES.fetch(privacy_profile).fetch(:trace_capture_allowed)
    end

    def zdr_required?
      provider_preferences[:zdr] == true
    end

    def to_h
      {
        privacy_profile: privacy_profile,
        workspace: workspace,
        provider_preferences: provider_preferences,
        guardrails: guardrails,
        trace_capture_allowed: trace_capture_allowed?
      }
    end
  end

  class << self
    def resolve(account: nil, preferences: nil, privacy_profile: nil, workspace: nil)
      profile_key = normalize_privacy_profile(
        privacy_profile.presence || runtime_preferences(account, preferences)['privacy_profile']
      )
      profile = PRIVACY_PROFILES.fetch(profile_key)
      resolved_workspace = normalize_workspace(workspace)

      Policy.new(
        privacy_profile: profile_key,
        workspace: resolved_workspace,
        provider_preferences: profile.slice(:allow_fallbacks, :data_collection, :zdr),
        guardrails: guardrails_for(profile_key, resolved_workspace)
      )
    end

    def provider_preferences(account: nil, preferences: nil, privacy_profile: nil, workspace: nil)
      resolve(
        account: account,
        preferences: preferences,
        privacy_profile: privacy_profile,
        workspace: workspace
      ).provider_preferences
    end

    def trace_capture_allowed?(account: nil, preferences: nil, privacy_profile: nil)
      resolve(account: account, preferences: preferences, privacy_profile: privacy_profile).trace_capture_allowed?
    end

    def supported_privacy_profile?(privacy_profile)
      PRIVACY_PROFILES.key?(privacy_profile.to_s)
    end

    private

    def normalize_privacy_profile(privacy_profile)
      profile = privacy_profile.to_s.presence || DEFAULT_PRIVACY_PROFILE
      return profile if supported_privacy_profile?(profile)

      raise ArgumentError, "Unsupported OpenRouter privacy profile: #{profile}"
    end

    def normalize_workspace(workspace)
      return workspace.to_s if workspace.present?
      return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)

      ENV.fetch('RAILS_ENV', ENV.fetch('RACK_ENV', 'development'))
    end

    def runtime_preferences(account, preferences)
      account_preferences = account_runtime_preferences(account)
      return account_preferences if preferences.blank?

      account_preferences.merge(preferences.to_h.stringify_keys)
    rescue StandardError
      {}
    end

    def account_runtime_preferences(account)
      return account.captain_runtime.to_h.stringify_keys if account.respond_to?(:captain_runtime)
      return account.captain_preferences[:runtime].to_h.stringify_keys if account.respond_to?(:captain_preferences)

      {}
    end

    def guardrails_for(profile_key, workspace)
      {
        budget: budget_guardrail(workspace),
        provider: guardrail('routing_profile_enforced', 'provider data_collection/ZDR preferences are compiled into every OpenRouter request'),
        model: guardrail('capability_resolver_enforced', 'model eligibility is checked by feature capability diagnostics'),
        zdr: guardrail(zdr_status_for(profile_key), 'OpenRouter provider.zdr controls zero-data-retention routing'),
        prompt_injection: guardrail('local_enforced', 'OneLink runtime blocks prompt-injection patterns before provider dispatch'),
        pii: guardrail('local_enforced', 'OneLink runtime blocks credential and secret leakage before provider dispatch')
      }
    end

    def budget_guardrail(workspace)
      guardrail(
        'workspace_required',
        'OpenRouter workspace budget guardrail must be configured outside application code'
      ).merge(workspace: workspace)
    end

    def guardrail(status, enforcement)
      { status: status, enforcement: enforcement }
    end

    def zdr_status_for(profile_key)
      profile_key == 'zdr_required' ? 'provider_required' : 'not_required'
    end
  end
end
