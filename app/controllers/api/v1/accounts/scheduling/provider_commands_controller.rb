class Api::V1::Accounts::Scheduling::ProviderCommandsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :set_command, only: [:show]

  def index
    commands = command_scope.order(created_at: :desc).limit(index_limit)
    render_payload(commands.map { |command| Integrations::Medelement::ProviderCommandPayloadBuilder.build(command) })
  end

  def show
    render_payload(Integrations::Medelement::ProviderCommandPayloadBuilder.build(@command))
  end

  def create
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: Current.account,
      hook: medelement_hook,
      appointment: appointment,
      contact: contact,
      operation: command_params[:operation],
      idempotency_key: command_params[:idempotency_key],
      company_cabinet_code: command_params[:company_cabinet_code],
      actor: Current.user,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at
    ).perform

    render_payload(Integrations::Medelement::ProviderCommandPayloadBuilder.build(command), status: :created)
  end

  private

  def command_scope
    Integrations::Medelement::ProviderCommand.where(account: Current.account)
  end

  def set_command
    @command = command_scope.find(params[:id])
  end

  def medelement_hook
    Integrations::Hook.where(account: Current.account, app_id: 'medelement').find(command_params[:hook_id])
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
      :hook_id, :appointment_id, :contact_id, :operation, :idempotency_key, :company_cabinet_code,
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
