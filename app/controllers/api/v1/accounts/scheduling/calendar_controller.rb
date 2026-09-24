class Api::V1::Accounts::Scheduling::CalendarController < Api::V1::Accounts::Scheduling::BaseController
  ALLOWED_VIEWS = %w[day week month list].freeze
  DEFAULT_APPOINTMENTS_PER_PAGE = 25
  MAX_APPOINTMENTS_PER_PAGE = 100
  MAX_RANGE = 92.days

  def show
    authorize Scheduling::Appointment, :index?
    from = parse_datetime_param!(params[:from], field_name: 'from')
    to = parse_datetime_param!(params[:to], field_name: 'to')
    validate_range!(from, to)
    result = Scheduling::CalendarViewService.new(
      account: Current.account,
      **calendar_options(from, to)
    ).perform

    render_payload(calendar_payload(result), meta: result[:meta])
  end

  private

  def calendar_options(from, to)
    {
      appointment_scope: appointment_scope,
      view: resolved_view,
      from: from,
      to: to,
      resource_ids: parse_id_list_param!(params[:resource_ids], field_name: 'resource_ids'),
      include_slots: parse_boolean(params[:include_slots]),
      duration_min: params[:duration_min],
      custom_attribute_filters: custom_attribute_filters_param,
      filters: appointment_filters,
      paginate_appointments: parse_boolean(params[:paginate_appointments]),
      appointment_page: appointment_page,
      appointments_per_page: appointments_per_page
    }
  end

  def calendar_payload(result)
    Scheduling::PayloadBuilder.calendar(result)
  end

  def appointment_scope
    Scheduling::AppointmentPolicy::Scope.new(
      pundit_user,
      Current.account.scheduling_appointments,
      capability: 'view'
    ).resolve
  end

  def validate_range!(from, to)
    raise ArgumentError, 'to must be after from' unless to > from
    return unless to - from > MAX_RANGE

    raise Scheduling::Error.new(
      code: 'CALENDAR_RANGE_TOO_LARGE',
      message: 'calendar range cannot exceed 92 days',
      status: :unprocessable_content
    )
  end

  def appointment_filters
    { statuses: parse_csv_ids(params[:status]) }
  end

  def appointment_page
    Integer(params[:page], exception: false).to_i.clamp(1, 10_000)
  end

  def appointments_per_page
    value = params[:per_page].presence || DEFAULT_APPOINTMENTS_PER_PAGE
    parsed_value = Integer(value, exception: false) || DEFAULT_APPOINTMENTS_PER_PAGE
    parsed_value.clamp(1, MAX_APPOINTMENTS_PER_PAGE)
  end

  def resolved_view
    view = params[:view].presence || 'week'
    return view if ALLOWED_VIEWS.include?(view)

    raise ArgumentError, "view must be one of: #{ALLOWED_VIEWS.join(', ')}"
  end
end
