class Integrations::Medelement::SyncCoordinatorService
  def initialize(hook:)
    @hook = hook
    @configuration = Integrations::Medelement::Configuration.new(hook: hook)
    @client = Integrations::Medelement::Client.new(configuration: configuration)
  end

  def perform
    return if hook.disabled?
    return unless hook.feature_allowed?

    Integrations::Medelement::ContactCustomAttributesSetupService.new(account: hook.account).perform

    if configuration.sync_specialists?
      Integrations::Medelement::SpecialistsSyncService.new(
        account: hook.account,
        client: client,
        configuration: configuration
      ).perform
    end

    return unless configuration.sync_receptions?

    Integrations::Medelement::ReceptionsSyncService.new(
      account: hook.account,
      client: client,
      configuration: configuration
    ).perform
  end

  private

  attr_reader :client, :configuration, :hook
end
