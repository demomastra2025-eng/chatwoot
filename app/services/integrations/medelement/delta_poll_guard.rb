# Fence every import and cursor commit against a disabled, removed or
# reconfigured integration after the provider response arrives.
class Integrations::Medelement::DeltaPollGuard
  IntegrationChangedError = Class.new(StandardError)
  CONFIGURATION_KEYS = %w[app_id access_token reference_id settings].freeze

  def initialize(hook:)
    @hook_id = hook.id
    @account_id = hook.account_id
    @configuration = hook.attributes.slice(*CONFIGURATION_KEYS).deep_dup
  end

  def synchronize
    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: @account_id, hook_id: @hook_id) do |current_hook|
      current = current_hook.attributes.slice(*CONFIGURATION_KEYS)
      unless current == @configuration && current_hook.enabled? && current_hook.feature_allowed?
        raise IntegrationChangedError, 'Medelement integration changed during delta poll'
      end

      yield current_hook
    end
  end
end
