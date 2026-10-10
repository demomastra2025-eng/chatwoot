class Captain::AppointmentContext
  BLOCK_KEYS = %w[nearest last_past last_cancelled all].freeze
  STATUSES = %w[scheduled completed cancelled no_show any].freeze
  DEFAULT_LIMIT = 10
  MAX_LIMIT = 20

  def initialize(account:, conversation:)
    @account = account
    @conversation = conversation
  end

  def appointments
    scope = @account.scheduling_appointments
    return scope.none if @conversation.blank? || @conversation.account_id != @account.id || @conversation.contact_id.blank?

    scope.where(contact_id: @conversation.contact_id)
         .where('COALESCE(patient_contact_id, contact_id) = ?', @conversation.contact_id)
  end

  def nearest(now: Time.current)
    upcoming(now).order(ends_at: :asc, id: :asc).includes(:resource, :service).first
  end

  def last_past(now: Time.current)
    past(now).order(ends_at: :desc, id: :desc).includes(:resource, :service).first
  end

  def last_cancelled
    cancelled.order(starts_at: :desc, id: :desc).includes(:resource, :service).first
  end

  def block(key, now: Time.current)
    raise ArgumentError, 'Invalid block' unless BLOCK_KEYS.include?(key.to_s)

    value = case key.to_s
            when 'nearest' then card(nearest(now: now))
            when 'last_past' then card(last_past(now: now))
            when 'last_cancelled' then card(last_cancelled)
            when 'all' then summary(now: now)
            end
    JSON.generate(value)
  end

  def list(**filters)
    status = filters.fetch(:status, 'any').to_s.presence || 'any'
    raise ArgumentError, 'Invalid status' unless STATUSES.include?(status)

    limit = integer_in_range(filters[:limit], default: DEFAULT_LIMIT, maximum: MAX_LIMIT, cap: true)
    offset = integer_in_range(filters[:offset], default: 0)
    from = parse_date(filters[:date_from])
    to = parse_date(filters[:date_to])
    raise ArgumentError, 'Invalid date range' if from && to && from > to

    scope = filtered_appointments(status: status, from: from, to: to, doctor: filters[:doctor])

    total = scope.count
    return { success: true, total: total, has_more: false, appointments: [] } if offset >= total

    records = scope.order(starts_at: :desc, id: :desc).offset(offset).limit(limit).includes(:resource, :service)
    { success: true, total: total, has_more: offset + limit < total, appointments: records.map { |record| card(record) } }
  end

  def card(appointment)
    return nil if appointment.blank?

    timezone = Captain::ContextFields.appointment_timezone_for(appointment, @account)
    local_time = appointment.starts_at.in_time_zone(timezone)
    {
      id: appointment.id,
      status: appointment.status == 'confirmed' ? 'scheduled' : appointment.status,
      date: local_time.strftime('%d.%m.%Y'),
      time: local_time.strftime('%H:%M'),
      doctor: appointment.resource&.name,
      service: appointment.service_name_snapshot.presence || appointment.service&.name
    }
  end

  private

  def filtered_appointments(status:, from:, to:, doctor:)
    scope = appointments
    scope = scope.where(status: %w[scheduled confirmed]) if status == 'scheduled'
    scope = scope.where(status: status) unless %w[any scheduled].include?(status)
    scope = scope.where('starts_at >= ?', day_start(from)) if from
    scope = scope.where('starts_at < ?', day_start(to + 1.day)) if to
    return scope if doctor.blank?

    names = @account.scheduling_resources.where('name ILIKE ?', "%#{Scheduling::Resource.sanitize_sql_like(doctor.to_s.strip)}%")
    scope.where(resource_id: names.select(:id))
  end

  def day_start(date)
    zone = ActiveSupport::TimeZone[@account.reporting_timezone] if @account.reporting_timezone.present?
    zone ||= ActiveSupport::TimeZone[Scheduling::Constants::DEFAULT_TIMEZONE]
    zone.local(date.year, date.month, date.day)
  end

  def upcoming(now)
    appointments.where.not(status: 'cancelled').where('ends_at > ?', now)
  end

  def past(now)
    appointments.where.not(status: 'cancelled').where('ends_at <= ?', now)
  end

  def cancelled
    appointments.where(status: 'cancelled')
  end

  def summary(now:)
    upcoming_count = upcoming(now).count
    past_count = past(now).count
    cancelled_count = cancelled.count
    {
      total: upcoming_count + past_count + cancelled_count,
      upcoming: upcoming_count,
      past: past_count,
      cancelled: cancelled_count,
      appointments: (
        upcoming(now).order(ends_at: :asc, id: :asc).limit(3).includes(:resource, :service).map { |record| card(record) } +
        past(now).order(ends_at: :desc, id: :desc).limit(2).includes(:resource, :service).map { |record| card(record) } +
        cancelled.order(starts_at: :desc, id: :desc).limit(1).includes(:resource, :service).map { |record| card(record) }
      ),
      empty: (upcoming_count + past_count + cancelled_count).zero? ? 'нет записей' : nil,
      hint: 'Остальные записи запросите через list_my_appointments'
    }
  end

  def parse_date(value)
    return if value.blank?

    raise ArgumentError, 'Invalid date' unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise ArgumentError, 'Invalid date'
  end

  def integer_in_range(value, default:, maximum: nil, cap: false)
    number = value.nil? ? default : Integer(value)
    raise ArgumentError, 'Invalid pagination' if number.negative? || (default.positive? && number.zero?)
    return maximum if maximum && cap && number > maximum
    raise ArgumentError, 'Invalid pagination' if maximum && number > maximum

    number
  rescue TypeError
    raise ArgumentError, 'Invalid pagination'
  end
end
