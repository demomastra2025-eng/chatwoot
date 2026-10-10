class Crm::Appointments::Facts
  FINGERPRINT_ATTRIBUTE_KEYS = %w[medelement_reception_code medelement_provider_sync_status provider_status_audit medelement_removed_at].freeze

  def self.provider_booked?(appointment)
    attributes = appointment.custom_attributes.to_h
    return false if attributes['medelement_reception_code'].blank?

    appointment.source == 'medelement' || attributes['medelement_provider_sync_status'] == 'succeeded'
  end

  def self.attended?(appointment)
    return false unless appointment.status == 'completed'

    audit = appointment.custom_attributes.to_h['provider_status_audit'].to_h
    return true if audit['reason'] == 'provider_explicit_completed'

    appointment.attendance_confirmed_at.present?
  end

  def self.timezone_for(account)
    ActiveSupport::TimeZone[account.reporting_timezone.presence || Time.zone&.name || 'UTC']
  end

  def initialize(deal:, now: Time.current)
    @deal = deal
    @now = now
    @timezone = self.class.timezone_for(deal.account)
    @appointments = deal.appointments.where(account_id: deal.account_id).ordered.to_a
  end

  attr_reader :appointments, :timezone

  def fingerprint
    values = appointments.map do |appointment|
      [appointment.id, appointment.status, appointment.starts_at.iso8601(6), appointment.ends_at.iso8601(6),
       appointment.attendance_confirmed_at&.iso8601(6), appointment.custom_attributes.to_h.slice(*FINGERPRINT_ATTRIBUTE_KEYS)]
    end
    Digest::SHA256.hexdigest(
      [values, deal.appointment_plan, deal.selected_appointment_id, configuration, local_today.iso8601, timezone.name, clock_facts].to_json
    )
  end

  def rule_matches?(rule)
    subset = scope_for(rule['scope'])
    return false if subset.empty?

    matches = subset.map { |appointment| Array(rule['conditions']).all? { |condition| condition_matches?(appointment, condition) } }
    rule['scope'] == 'all' ? matches.all? : matches.any?
  end

  def success?
    case configuration['success_mode']
    when 'any_attended' then appointments.any? { |appointment| self.class.attended?(appointment) }
    when 'selected_attended' then selected.any? { |appointment| self.class.attended?(appointment) }
    when 'all_required_attended' then all_required_attended?
    else false
    end
  end

  def next_check_at
    return unless configuration['enabled'] && configuration['rules'].any? { |rule| (Array(rule['conditions']) & %w[today tomorrow past future]).any? || rule['scope'] == 'nearest' }
    return if appointments.empty?

    tomorrow = local_today + 1.day
    midnight = timezone.local(tomorrow.year, tomorrow.month, tomorrow.day)
    next_boundary = appointments.flat_map { |appointment| [appointment.starts_at, appointment.ends_at + 1.second] }.select { |time| time > now }.min
    [midnight, next_boundary].compact.min
  end

  private

  attr_reader :deal, :now

  def configuration
    @configuration ||= Crm::Appointments::Configuration.for(deal.pipeline)
  end

  def local_today
    now.in_time_zone(timezone).to_date
  end

  def clock_facts
    configuration['rules'].map do |rule|
      conditions = Array(rule['conditions']) & %w[today tomorrow past future]
      [rule['scope'] == 'nearest' ? scope_for('nearest').map(&:id) : nil,
       appointments.map { |appointment| conditions.map { |condition| condition_matches?(appointment, condition) } }]
    end
  end

  def selected
    appointments.select { |appointment| appointment.id == deal.selected_appointment_id }
  end

  def scope_for(scope)
    case scope
    when 'selected' then selected
    when 'nearest'
      upcoming = appointments.select { |appointment| appointment.ends_at >= now }
      [upcoming.min_by(&:starts_at) || appointments.max_by(&:starts_at)].compact
    else appointments
    end
  end

  def all_required_attended?
    required = Array(deal.appointment_plan).select { |entry| entry['required'] != false }
    return false if required.empty?

    required.all? do |entry|
      appointment = appointments.find { |record| record.id == entry['appointment_id'].to_i }
      appointment && self.class.attended?(appointment)
    end
  end

  def condition_matches?(appointment, condition)
    case condition
    when 'provider_confirmed' then self.class.provider_booked?(appointment) && appointment.status.in?(%w[scheduled confirmed])
    when 'patient_confirmed' then appointment.status == 'confirmed'
    when 'scheduled' then appointment.status.in?(%w[scheduled confirmed])
    when 'attended' then self.class.attended?(appointment)
    when 'cancelled' then appointment.status == 'cancelled'
    when 'no_show' then appointment.status == 'no_show'
    when 'today' then appointment.starts_at.in_time_zone(timezone).to_date == local_today
    when 'tomorrow' then appointment.starts_at.in_time_zone(timezone).to_date == local_today + 1.day
    when 'past' then appointment.ends_at < now
    when 'future' then appointment.starts_at > now
    else false
    end
  end
end
