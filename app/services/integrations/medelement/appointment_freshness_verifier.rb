class Integrations::Medelement::AppointmentFreshnessVerifier
  Result = Data.define(:status, :reason, :checked_at, :command_id, :command_status) do
    def allowed?
      status == 'fresh' || status == 'not_applicable'
    end

    def terminal?
      status == 'cancelled'
    end
  end

  def initialize(appointment:, client: nil)
    @appointment = appointment
    @configuration = configuration
    @client = client
  end

  def perform
    @checked_at = Time.current
    return result('not_applicable') unless provider_appointment?
    return result('cancelled', reason: 'local_appointment_cancelled') if appointment.status == 'cancelled'
    return command_block_result if command_unfinished?
    return result('blocked', reason: 'provider_reception_missing') if reception_code.blank?
    return result('blocked', reason: 'provider_configuration_missing') if @configuration.blank?

    verify_reception(client.get_reception(reception_code: reception_code, version: :v2))
  rescue Integrations::Medelement::Client::ApiError => e
    log_unavailable(e)
    result('blocked', reason: 'provider_unavailable')
  rescue StandardError => e
    log_unavailable(e)
    result('blocked', reason: 'provider_response_invalid')
  end

  private

  attr_reader :appointment

  def command_unfinished?
    latest_command&.status.in?(Integrations::Medelement::ProviderCommand::UNFINISHED_STATUSES)
  end

  def command_block_result
    result('blocked', reason: "provider_command_#{latest_command.status}")
  end

  def verify_reception(reception)
    return invalid_reception_result(reception) if invalid_reception?(reception)
    return result('blocked', reason: 'provider_reception_mismatch') unless reception_matches?(reception)
    return result('cancelled', reason: 'provider_reception_cancelled') if removed?(reception)
    return result('blocked', reason: 'provider_response_invalid') unless active?(reception)
    return result('blocked', reason: 'provider_reception_time_changed') unless time_matches?(reception)
    return result('blocked', reason: 'provider_reception_specialist_changed') unless specialist_matches?(reception)

    result('fresh')
  end

  def invalid_reception_result(reception)
    result('blocked', reason: reception.blank? ? 'provider_reception_missing' : 'provider_response_invalid')
  end

  def invalid_reception?(reception)
    reception.blank? || !reception.is_a?(Hash)
  end

  def provider_appointment?
    specialist_code.present? || reception_code.present?
  end

  def latest_command
    @latest_command ||= Integrations::Medelement::ProviderCommand.where(
      account_id: appointment.account_id,
      appointment_id: appointment.id
    ).order(created_at: :desc, id: :desc).first
  end

  def configuration
    hook = appointment.account.hooks.enabled.find_by(app_id: 'medelement')
    return if hook.blank? || !hook.feature_allowed?

    Integrations::Medelement::Configuration.new(hook: hook)
  end

  def client
    @client ||= Integrations::Medelement::Client.new(configuration: @configuration)
  end

  def reception_code
    @reception_code ||= appointment.custom_attributes.to_h['medelement_reception_code'].presence ||
                        appointment.external_ref.to_s.delete_prefix('medelement:reception:').presence
  end

  def specialist_code
    appointment.resource&.custom_attributes.to_h['medelement_specialist_code'].to_s.presence
  end

  def removed?(reception)
    removed_state(reception) == 1
  end

  def reception_matches?(reception)
    reception['RECEPTION_CODE'].to_s == reception_code
  end

  def active?(reception)
    removed_state(reception)&.zero? || false
  end

  def removed_state(reception)
    value = Integer(reception['REMOVED'], exception: false)
    value if value.in?([0, 1])
  end

  def time_matches?(reception)
    provider_time(reception['STARTTIME'])&.to_i == appointment.starts_at.to_i &&
      provider_time(reception['ENDTIME'])&.to_i == appointment.ends_at.to_i
  end

  def specialist_matches?(reception)
    return true if specialist_code.blank?
    return false if reception['SPECIALIST_CODE'].blank?

    reception['SPECIALIST_CODE'].to_s == specialist_code
  end

  def provider_time(value)
    ActiveSupport::TimeZone[@configuration.time_zone]&.parse(value.to_s)
  end

  def result(status, reason: nil)
    Result.new(
      status: status,
      reason: reason,
      checked_at: @checked_at || Time.current,
      command_id: latest_command&.id,
      command_status: latest_command&.status
    )
  end

  def log_unavailable(error)
    Rails.logger.warn(
      "[MEDELEMENT::APPOINTMENT_FRESHNESS] account=#{appointment.account_id} appointment=#{appointment.id} " \
      "error=#{error.class.name}"
    )
  end
end
