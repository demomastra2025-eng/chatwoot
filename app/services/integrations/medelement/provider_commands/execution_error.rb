class Integrations::Medelement::ProviderCommands::ExecutionError < StandardError
  attr_reader :code

  def initialize(code:, message:, reconciliation: false)
    super(message)
    @code = code
    @reconciliation = reconciliation
  end

  def reconciliation?
    @reconciliation
  end
end
