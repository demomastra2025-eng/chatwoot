class Api::V1::Accounts::Scheduling::CalendarController < Api::V1::Accounts::Scheduling::BaseController
  ALLOWED_VIEWS = %w[day week month list].freeze

  def show
    result = Scheduling::CalendarViewService.new(
      account: Current.account,
      view: resolved_view,
      from: parse_datetime_param!(params[:from], field_name: 'from'),
      to: parse_datetime_param!(params[:to], field_name: 'to'),
      resource_ids: parse_id_list_param!(params[:resource_ids], field_name: 'resource_ids'),
      include_slots: parse_boolean(params[:include_slots]),
      duration_min: params[:duration_min],
      custom_attribute_filters: custom_attribute_filters_param,
      filters: appointment_filters
    ).perform

    render_payload(Scheduling::PayloadBuilder.calendar(result))
  end

  private

  def appointment_filters
    {
      statuses: parse_csv_ids(params[:status]),
      payment_statuses: parse_csv_ids(params[:payment_status])
    }
  end

  def resolved_view
    view = params[:view].presence || 'week'
    return view if ALLOWED_VIEWS.include?(view)

    raise ArgumentError, "view must be one of: #{ALLOWED_VIEWS.join(', ')}"
  end
end
