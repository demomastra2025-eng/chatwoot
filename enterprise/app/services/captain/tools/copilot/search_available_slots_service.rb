class Captain::Tools::Copilot::SearchAvailableSlotsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_available_slots'
  end

  description 'Search available appointment slots for one or more specialists'
  param :from, type: :string, desc: 'Range start datetime', required: true
  param :to, type: :string, desc: 'Range end datetime', required: true
  param :resource_ids, type: :string, desc: 'Optional comma-separated specialist resource IDs', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes', required: false

  def execute(from:, to:, resource_ids: nil, duration_min: nil)
    result = Scheduling::CalendarViewService.new(
      account: account,
      view: 'week',
      from: parse_datetime(from, field_name: 'from', required: true),
      to: parse_datetime(to, field_name: 'to', required: true),
      resource_ids: parse_csv_ids(resource_ids),
      include_slots: true,
      duration_min: duration_min
    ).perform

    formatted_payload(
      range: result[:range],
      resources: result[:resources].map { |resource| Scheduling::PayloadBuilder.resource(resource) },
      slots: result[:slots].first(100)
    )
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
