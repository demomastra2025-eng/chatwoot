# frozen_string_literal: true

require 'digest'

class Llm::Monitoring::AlertNotifier
  DEFAULT_COOLDOWN = 60.minutes
  DEFAULT_INCLUDE_LIVE_EVALS = false
  STATE_ROOT_KEY = 'captain_observability_state'
  STATE_KEY = 'alert_delivery'
  SEVERITY_RANK = {
    'warning' => 1,
    'critical' => 2
  }.freeze
  EVAL_SEVERITY_BY_CHECK = {
    'deterministic_evals' => 'critical',
    'live_evals' => 'warning'
  }.freeze

  class << self
    def state_for(account)
      raw = account&.internal_attributes.to_h.deep_stringify_keys.dig(STATE_ROOT_KEY, STATE_KEY).to_h

      {
        status: raw['status'].presence || 'idle',
        fingerprint: raw['fingerprint'].presence,
        active_alert_count: raw['active_alert_count'].to_i,
        last_delivery_at: raw['last_delivery_at'].presence,
        last_delivery_channels: Array(raw['last_delivery_channels']).compact,
        last_resolved_at: raw['last_resolved_at'].presence,
        incidents: Array(raw['incidents']).map do |incident|
          incident.to_h.deep_stringify_keys.slice(
            'source', 'name', 'suite_id', 'severity', 'message', 'failed_count', 'total_count'
          )
        end
      }.compact
    end
  end

  def initialize(account:, now: Time.current, runner: nil, include_live_evals: DEFAULT_INCLUDE_LIVE_EVALS)
    @account = account
    @now = now
    @runner = runner
    @include_live_evals = include_live_evals
  end

  def call
    channels = alert_channels
    return result(status: 'disabled') unless channels_enabled?(channels)

    report = release_check_report
    incidents = filtered_incidents(report)

    if incidents.blank?
      persist_state(status: 'clear', incidents: [])
      return result(status: 'clear', report:, incidents:)
    end

    fingerprint = fingerprint_for(incidents)

    if throttled?(incidents)
      persist_state(status: 'throttled', incidents: incidents, fingerprint: fingerprint)
      return result(status: 'throttled', report:, incidents:)
    end

    deliveries = deliver_incidents(report:, incidents:)
    status = deliveries.any? ? 'delivered' : 'no_channels'
    persist_state(status:, incidents:, deliveries:, fingerprint: fingerprint)

    result(status:, report:, incidents:, deliveries:)
  end

  private

  def alert_channels
    @alert_channels ||= Llm::Monitoring::AccountPreferences.for(@account).fetch('alert_channels', {})
  end

  def channels_enabled?(channels)
    ActiveModel::Type::Boolean.new.cast(channels['enabled'])
  end

  def release_check_report
    runner = @runner || Llm::ReleaseCheck::Runner.new(
      account: @account,
      date_range: Llm::Monitoring::AccountPreferences.default_date_range(account: @account),
      include_live_evals: @include_live_evals
    )

    runner.call.to_h.deep_stringify_keys
  end

  def filtered_incidents(report)
    incidents_for(report).select do |incident|
      severity_rank(incident['severity']) >= severity_rank(alert_channels['minimum_severity'])
    end
  end

  def incidents_for(report)
    selected_checks = Array(alert_channels['notify_on']).presence || ['operational_release_gate']
    incidents = []

    if selected_checks.include?('operational_release_gate')
      incidents.concat(Array(report.dig('operational', 'alerts', 'alerts')).map { |alert| operational_incident(alert) })
    end

    %w[deterministic_evals live_evals].each do |check_name|
      next unless selected_checks.include?(check_name)

      suites = Array(report.dig('evals', check_name.sub('_evals', ''), 'suites'))
      suites.each do |suite|
        next if suite['status'].to_s == 'pass'

        incidents << eval_incident(check_name, suite)
      end
    end

    incidents.compact
  end

  def operational_incident(alert)
    payload = alert.to_h.deep_stringify_keys

    {
      'source' => 'operational',
      'name' => payload['name'].presence || 'operational_release_gate',
      'severity' => normalized_severity(payload['severity']),
      'message' => payload['message'].presence || payload['name'].to_s.humanize,
      'actual' => payload['actual'],
      'expected' => payload['expected']
    }.compact
  end

  def eval_incident(check_name, suite)
    payload = suite.to_h.deep_stringify_keys

    {
      'source' => check_name,
      'name' => check_name,
      'suite_id' => payload['suite_id'],
      'severity' => EVAL_SEVERITY_BY_CHECK.fetch(check_name, 'warning'),
      'message' => "#{payload['suite_id'].presence || check_name} failed",
      'failed_count' => payload['failed_count'],
      'error_count' => payload['error_count'],
      'total_count' => payload['total_count']
    }.compact
  end

  def recipients
    explicit = Array(alert_channels['email_recipients']).filter_map do |recipient|
      normalized = recipient.to_s.strip.downcase
      normalized if normalized.present?
    end

    return explicit.uniq if explicit.present?

    @account.administrators.pluck(:email).filter_map do |email|
      normalized = email.to_s.strip.downcase
      normalized if normalized.present?
    end.uniq
  end

  def throttled?(incidents)
    state = self.class.state_for(@account)
    return false if state[:last_delivery_at].blank?
    return false if state[:fingerprint] != fingerprint_for(incidents)

    Time.zone.parse(state[:last_delivery_at]) > (@now - DEFAULT_COOLDOWN)
  rescue StandardError
    false
  end

  def deliver_incidents(report:, incidents:)
    deliveries = []

    if recipients.present?
      mail_delivery = AdministratorNotifications::CaptainObservabilityMailer
        .with(account: @account)
        .alert_digest(@account, report:, incidents:, recipients: recipients)
      if mail_delivery.present?
        mail_delivery.deliver_later
        deliveries << 'email'
      end
    end

    if alert_channels['webhook_url'].present?
      WebhookJob.perform_later(
        alert_channels['webhook_url'],
        webhook_payload(report:, incidents:),
        :account_webhook
      )
      deliveries << 'webhook'
    end

    deliveries
  end

  def webhook_payload(report:, incidents:)
    {
      event: 'captain.observability.alert_digest',
      account: {
        id: @account.id,
        name: @account.name
      },
      delivered_at: @now.iso8601,
      incidents: incidents,
      report: report.slice('generated_at', 'date_range', 'checks', 'operational', 'evals')
    }
  end

  def persist_state(status:, incidents:, deliveries: [], fingerprint: nil)
    @account.with_lock do
      @account.reload
      internal_attributes = @account.internal_attributes.to_h.deep_stringify_keys
      captain_state = internal_attributes[STATE_ROOT_KEY].to_h
      previous_state = captain_state[STATE_KEY].to_h

      next_state = previous_state.merge(
        'status' => status,
        'fingerprint' => fingerprint,
        'active_alert_count' => incidents.size,
        'incidents' => incidents
      )

      if status == 'delivered'
        next_state['last_delivery_at'] = @now.iso8601
        next_state['last_delivery_channels'] = deliveries
      elsif status == 'clear'
        next_state['last_resolved_at'] = @now.iso8601
      end

      captain_state[STATE_KEY] = next_state
      internal_attributes[STATE_ROOT_KEY] = captain_state

      @account.update_columns(internal_attributes: internal_attributes, updated_at: @now)
    end
  end

  def result(status:, report: nil, incidents: [], deliveries: [])
    {
      status: status,
      account_id: @account.id,
      incident_count: incidents.size,
      deliveries: deliveries,
      report: report,
      incidents: incidents
    }.compact
  end

  def fingerprint_for(incidents)
    Digest::SHA256.hexdigest(
      incidents.map { |incident| incident.to_h.deep_stringify_keys.sort.to_h }.sort_by { |incident| incident.values.join(':') }.to_json
    )
  end

  def normalized_severity(value)
    severity = value.to_s
    SEVERITY_RANK.key?(severity) ? severity : 'warning'
  end

  def severity_rank(value)
    SEVERITY_RANK.fetch(normalized_severity(value), SEVERITY_RANK['warning'])
  end
end
