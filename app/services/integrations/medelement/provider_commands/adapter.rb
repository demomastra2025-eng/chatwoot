class Integrations::Medelement::ProviderCommands::Adapter
  PROVIDER = 'medelement'.freeze

  attr_reader :account, :hook

  def initialize(account:, hook:)
    @account = account
    @hook = hook
  end

  def command_scope
    Integrations::Medelement::ProviderCommand.where(account: account)
  end

  def serialize(command)
    Integrations::Medelement::ProviderCommandPayloadBuilder.build(command).merge(provider: PROVIDER)
  end

  # Mirrors the provider-neutral command API with explicit provider-owned implementation details.
  # rubocop:disable Metrics/ParameterLists
  def create_command(
    appointment:, contact:, operation:, idempotency_key:, company_cabinet_code:, actor:,
    desired_starts_at:, desired_ends_at:
  )
    Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: operation,
      idempotency_key: idempotency_key,
      company_cabinet_code: company_cabinet_code,
      actor: actor,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at
    ).perform
  end
  # rubocop:enable Metrics/ParameterLists

  def cancel_command(command:, actor:)
    Integrations::Medelement::ProviderCommands::CancelService.new(command: command, actor: actor).perform
  end

  def patient_candidates(command:, actor:)
    patient_actions(command: command, actor: actor).candidates
  end

  def select_patient(command:, actor:, token:)
    patient_actions(command: command, actor: actor).select!(token: token)
  end

  def confirm_patient_creation(command:, actor:)
    patient_actions(command: command, actor: actor).confirm_creation!
  end

  def retry_phone_mismatch(command:, actor:)
    patient_actions(command: command, actor: actor).retry_phone_mismatch!
  end

  private

  def patient_actions(command:, actor:)
    Integrations::Medelement::ProviderCommands::PatientActionsService.new(command: command, actor: actor)
  end
end
