class Api::V1::Accounts::Scheduling::ProviderCommandsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :set_provider_adapter
  before_action :set_command, only: [:show, :confirm, :cancel, :patient_candidates, :select_patient, :confirm_patient_creation]

  def index
    commands = provider_adapter.command_scope
    commands = commands.where(appointment_id: command_params[:appointment_id]) if command_params[:appointment_id].present?
    commands = commands.unfinished if ActiveModel::Type::Boolean.new.cast(command_params[:active_only])
    commands = commands.order(created_at: :desc).limit(index_limit)
    render_payload(commands.map { |command| provider_adapter.serialize(command) })
  end

  def show
    render_payload(provider_adapter.serialize(@command))
  end

  def create
    command = provider_adapter.create_command(
      appointment: appointment,
      contact: contact,
      operation: command_params[:operation],
      idempotency_key: command_params[:idempotency_key],
      company_cabinet_code: command_params[:company_cabinet_code],
      actor: Current.user,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at
    )

    render_payload(provider_adapter.serialize(command), status: :created)
  end

  def confirm
    confirmation_request = @command.confirmation_request
    if confirmation_request.blank?
      raise Scheduling::Error.new(
        code: 'SCHEDULING_PROVIDER_CONFIRMATION_NOT_FOUND',
        message: 'Provider command confirmation request not found',
        status: :unprocessable_entity
      )
    end

    Confirmations::ResolveService.new(
      account: Current.account,
      confirmation_request: confirmation_request,
      decision: 'confirmed',
      source: 'manual',
      actor: Current.user,
      metadata: { surface: 'scheduling_dashboard' }
    ).perform

    render_payload(provider_adapter.serialize(@command.reload))
  end

  def cancel
    command = provider_adapter.cancel_command(
      command: @command,
      actor: Current.user
    )

    render_payload(provider_adapter.serialize(command))
  end

  def patient_candidates
    candidates = provider_adapter.patient_candidates(command: @command, actor: Current.user)
    render_payload({ candidates: candidates, count: candidates.size })
  end

  def select_patient
    command = provider_adapter.select_patient(
      command: @command,
      actor: Current.user,
      token: command_params[:patient_token]
    )
    render_payload(provider_adapter.serialize(command))
  end

  def confirm_patient_creation
    command = provider_adapter.confirm_patient_creation(command: @command, actor: Current.user)
    render_payload(provider_adapter.serialize(command))
  end

  private

  attr_reader :provider_adapter

  def set_provider_adapter
    @provider_adapter = Scheduling::ProviderCommands::Registry.resolve!(
      account: Current.account,
      provider: command_params[:provider],
      hook_id: command_params[:hook_id],
      require_hook: action_name == 'create'
    )
  end

  def set_command
    @command = provider_adapter.command_scope.find(params[:id])
  end

  def appointment
    return @appointment if defined?(@appointment)

    @appointment = Current.account.scheduling_appointments.find(command_params[:appointment_id]) if command_params[:appointment_id].present?
  end

  def contact
    return @contact if defined?(@contact)

    @contact = if command_params[:contact_id].present?
                 Current.account.contacts.find(command_params[:contact_id])
               else
                 appointment&.contact
               end
  end

  def command_params
    params.permit(
      :provider, :hook_id, :appointment_id, :contact_id, :operation, :idempotency_key, :company_cabinet_code,
      :active_only,
      :patient_token,
      :desired_starts_at, :desired_ends_at
    )
  end

  def desired_starts_at
    parse_datetime_param!(command_params[:desired_starts_at], field_name: 'desired_starts_at', required: false)
  end

  def desired_ends_at
    parse_datetime_param!(command_params[:desired_ends_at], field_name: 'desired_ends_at', required: false)
  end

  def index_limit
    params.fetch(:limit, 50).to_i.clamp(1, 100)
  end
end
