class Scheduling::AiBookingProviderCheckJob < ApplicationJob
  queue_as :scheduled_jobs

  MAX_CHECKS_PER_RUN = 50
  MAX_CHECKS_PER_DAY = 500
  CHECK_WINDOW = 15.minutes
  CLAIM_TTL = 2.days.to_i

  def perform
    return unless ENV['AI_BOOKING_PROVIDER_CHECK_ENABLED'] == 'true'

    @now = Time.current
    @request_count = 0
    candidates.each do |command, checkpoint|
      break if @request_count >= MAX_CHECKS_PER_RUN

      check(command, checkpoint)
    end
  end

  private

  def candidates
    command_class = Integrations::Medelement::ProviderCommand
    scope = command_class.joins(:appointment).where(operation: 'create_reception', status: 'succeeded')
    scope = scope.where(
      "scheduling_appointments.source = 'captain' OR " \
      "medelement_provider_commands.execution_state #>> '{request_snapshot,actor,type}' = 'Captain::Assistant'"
    )
    checkpoints = [[scope.where(executed_at: (@now - 15.minutes - CHECK_WINDOW)..(@now - 15.minutes)), 'after_success']]
    [24.hours, 2.hours].each do |before_start|
      checkpoints << start_checkpoint(scope, before_start)
    end
    rows = checkpoints.flat_map do |relation, checkpoint|
      relation.order(:id).limit(MAX_CHECKS_PER_RUN).map { |command| [command, checkpoint] }
    end
    rows.uniq { |command, _checkpoint| command.id }.first(MAX_CHECKS_PER_RUN)
  end

  def start_checkpoint(scope, before_start)
    range = (@now + before_start - CHECK_WINDOW)..(@now + before_start)
    [scope.where(scheduling_appointments: { starts_at: range }), "before_#{before_start.to_i}"]
  end

  def check(command, checkpoint)
    return unless eligible?(command)

    key = "AI_BOOKING_PROVIDER_CHECK:#{command.id}:#{checkpoint}"
    return unless Redis::Alfred.set(key, true, nx: true, ex: CLAIM_TTL)

    verify_claimed(command, checkpoint, key)
  end

  def eligible?(command)
    command.appointment&.account_id == command.account_id && command.request_snapshot_valid? &&
      Integrations::Medelement::ProviderCommands::ReceptionVerifier.valid_reception_code?(command.provider_reception_code)
  end

  def verify_claimed(command, checkpoint, key)
    result = read(command)
    result = read(command) if result[:checked] && !result[:matched]
    Redis::Alfred.delete(key) unless result[:checked]
    return unless result[:checked] && !result[:matched]

    Rails.logger.error({ event: 'ai_booking_provider_mismatch', severity: 'critical',
                         account_id: command.account_id, appointment_id: command.appointment_id,
                         command_id: command.id, rule: 'A3_PROVIDER_MISMATCH', checkpoint: checkpoint }.to_json)
  end

  def read(command)
    client = client_for(command)
    return { checked: false } unless client
    return { checked: false } unless reserve_request

    detail = client.get_reception(reception_code: command.provider_reception_code, version: :v1)
    verifier = Integrations::Medelement::ProviderCommands::ReceptionVerifier.new(command: command)
    { checked: detail.is_a?(Hash), matched: verifier.destination_match?(detail, expected_reception_code: command.provider_reception_code) }
  rescue Integrations::Medelement::Client::ApiError => e
    return { checked: true, matched: false } if e.status == 404

    Rails.logger.warn({ event: 'ai_booking_provider_not_checked', command_id: command.id, status: e.status }.to_json)
    { checked: false }
  end

  def reserve_request
    return false if @request_count >= MAX_CHECKS_PER_RUN

    key = "AI_BOOKING_PROVIDER_DAILY:#{@now.utc.to_date}"
    Redis::Alfred.set(key, 0, nx: true, ex: 2.days.to_i)
    return false if Redis::Alfred.incr(key) > MAX_CHECKS_PER_DAY

    @request_count += 1
    true
  end

  def client_for(command)
    hook = command.hook
    return unless hook&.enabled? && hook.app_id == 'medelement' && hook.account_id == command.account_id

    Integrations::Medelement::Client.new(configuration: Integrations::Medelement::Configuration.new(hook: hook))
  end
end
