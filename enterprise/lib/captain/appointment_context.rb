class Captain::AppointmentContext
  BLOCK_KEYS = %w[nearest last_past last_cancelled all summary].freeze
  STATUSES = %w[scheduled completed cancelled no_show any].freeze
  DEFAULT_LIMIT = 10
  MAX_LIMIT = 20
  # Said with an empty list: the list covers this contact and the patients linked to it, and nothing else, so an empty answer is no
  # proof that the patient has no booking (the agent of the eval of 27.10 told patients that there was nothing to cancel).
  NOTHING_FOUND_NOTE = 'No appointment matched for this patient and the patients linked to this contact. That does not prove the ' \
                       'patient has no appointment: it may be booked on another phone or under another name. Never tell the patient ' \
                       'that there is no appointment or nothing to cancel. Ask for the IIN of the patient and look it up with ' \
                       'search_appointments, or leave the request to staff and say that a staff member will check.'.freeze

  def initialize(account:, conversation: nil, contact_id: nil)
    @account = account
    @conversation = conversation
    @contact_id = contact_id || conversation&.contact_id
  end

  # The contact's own appointments: the visits of the contact as the patient. They are what the prompt shows (the summary and the
  # nearest, last past and last cancelled cards) and what an agent may change by an ID alone.
  def appointments
    scope = @account.scheduling_appointments
    return scope.none if @conversation && @conversation.account_id != @account.id
    return scope.none unless @account.contacts.exists?(id: @contact_id)

    scope.where(contact_id: @contact_id)
         .where('COALESCE(patient_contact_id, contact_id) = ?', @contact_id)
  end

  # The appointments of the contact and of every patient linked to it: a child or a relative booked from this chat, a patient card
  # that shares the number (Scheduling::PatientContextQuery, the circle the staff's patient selector shows). What the agent looks
  # up (list_my_appointments, search_appointments) covers the whole family: a lookup of the contact's own card alone told a patient
  # who asked to cancel the visit of a child that there was nothing to cancel. A booking made from outside that circle, also one
  # that names the contact as its patient, stays out. A change of the appointment of another patient still needs its task token and
  # the patient's confirmation (AppointmentAccess).
  def linked_appointments
    scope = @account.scheduling_appointments
    return scope.none if @conversation && @conversation.account_id != @account.id

    ids = patient_contact_ids
    scope.where(contact_id: ids)
         .where('COALESCE(scheduling_appointments.patient_contact_id, scheduling_appointments.contact_id) IN (?)', ids)
  end

  # The contact and the patients linked to it; empty when the contact is not one of the account.
  def patient_contact_ids
    @patient_contact_ids ||= begin
      contact = @account.contacts.find_by(id: @contact_id)
      contact ? Scheduling::PatientContextQuery.new(account: @account, contact: contact).patient_ids : []
    end
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
            when 'summary' then compact_summary(now: now)
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
    return empty_list(total) if offset >= total

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
    }.merge(other_patient(appointment)).merge(unconfirmed_reschedule(appointment, timezone))
  end

  def compact_summary(now: Time.current)
    scopes = { upcoming: upcoming(now), past: past(now), cancelled: cancelled }
    groups = Captain::ContextSummary::APPOINTMENT_GROUPS.map do |key, config|
      scope = scopes.fetch(key)
      total = scope.count
      order = if key == :upcoming
                sql = Scheduling::Appointment.sanitize_sql_array(['CASE WHEN starts_at <= ? THEN 0 ELSE 1 END, starts_at ASC, id ASC', now])
                Arel.sql(sql)
              elsif key == :past
                { ends_at: :desc, id: :desc }
              else
                { starts_at: :desc, id: :desc }
              end
      items = scope.reorder(order).limit(config[:limit]).includes(:resource, :service).map do |record|
        data = card(record)
        data.merge(title: [data[:service], data[:doctor]].compact.join(' — '), starts_at: record.starts_at.iso8601, ends_at: record.ends_at.iso8601)
      end
      Captain::ContextSummary.group(key: key, total: total, items: items, config: config)
    end
    Captain::ContextSummary.build(kind: 'appointments', groups: groups, contact_id: @contact_id)
  end

  private

  # No card to list (nothing matched, or the offset is past the end); an empty list carries the note that it proves nothing.
  def empty_list(total)
    list = { success: true, total: total, has_more: false, appointments: [] }
    total.zero? ? list.merge(note: NOTHING_FOUND_NOTE) : list
  end

  # The name of the patient of a visit that is not the contact's own (a child, a relative), so the agent never reads it as the
  # contact's visit; nothing for the contact's own visits.
  def other_patient(appointment)
    return {} if (appointment.patient_contact_id || appointment.contact_id) == @contact_id

    { patient_name: appointment.client_name }
  end

  # The card time is the one MedElement confirmed. A reschedule it has not confirmed is a request, never the appointment time.
  def unconfirmed_reschedule(appointment, timezone)
    move = Integrations::Medelement::AppointmentMoveState.read(appointment)
    return {} if move.blank?

    requested = Integrations::Medelement::AppointmentMoveState.time(move, 'requested_starts_at')&.in_time_zone(timezone)
    { reschedule: { state: move['state'], requested_time_confirmed: false, requested_date: requested&.strftime('%d.%m.%Y'),
                    requested_time: requested&.strftime('%H:%M') }.compact }
  end

  def filtered_appointments(status:, from:, to:, doctor:)
    scope = linked_appointments
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
