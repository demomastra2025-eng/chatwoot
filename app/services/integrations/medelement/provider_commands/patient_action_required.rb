class Integrations::Medelement::ProviderCommands::PatientActionRequired < StandardError
  STATUSES = %w[awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh].freeze

  attr_reader :code, :metadata, :status

  def initialize(status:, code:, metadata: {})
    raise ArgumentError, 'unsupported patient action status' unless status.in?(STATUSES)

    super(code)
    @status = status
    @code = code
    @metadata = metadata.to_h
  end
end
