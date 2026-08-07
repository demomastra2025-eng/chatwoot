class Scheduling::ProviderCommands::Registry
  ADAPTERS = {
    'medelement' => 'Integrations::Medelement::ProviderCommands::Adapter'
  }.freeze

  class << self
    def resolve!(account:, provider: nil, hook_id: nil, require_hook: true)
      hook = resolve_hook(account: account, provider: provider, hook_id: hook_id)
      provider_name = hook&.app_id || resolve_provider!(provider)
      raise provider_not_configured_error if require_hook && hook.blank?

      adapter_class(provider_name).new(account: account, hook: hook)
    end

    private

    def resolve_hook(account:, provider:, hook_id:)
      scope = Integrations::Hook.where(account: account, app_id: ADAPTERS.keys)
      return scope.find(hook_id) if hook_id.present?
      return scope.where(app_id: provider.to_s).where(status: Integrations::Hook.statuses[:enabled]).order(:id).first if provider.present?

      enabled = scope.where(status: Integrations::Hook.statuses[:enabled]).order(:id).to_a
      return enabled.first if enabled.one?
      return if enabled.empty?

      raise Scheduling::Error.new(
        code: 'SCHEDULING_PROVIDER_REQUIRED',
        message: 'Scheduling provider must be selected',
        status: :unprocessable_content
      )
    end

    def resolve_provider!(provider)
      return provider.to_s if provider.present?
      return ADAPTERS.keys.first if ADAPTERS.one?

      raise Scheduling::Error.new(
        code: 'SCHEDULING_PROVIDER_REQUIRED',
        message: 'Scheduling provider must be selected',
        status: :unprocessable_content
      )
    end

    def provider_not_configured_error
      Scheduling::Error.new(
        code: 'SCHEDULING_PROVIDER_NOT_CONFIGURED',
        message: 'No scheduling provider is configured',
        status: :unprocessable_content
      )
    end

    def adapter_class(provider)
      ADAPTERS.fetch(provider.to_s).constantize
    rescue KeyError
      raise Scheduling::Error.new(
        code: 'SCHEDULING_PROVIDER_UNSUPPORTED',
        message: 'Scheduling provider is not supported',
        status: :unprocessable_content
      )
    end
  end
end
