class Captain::Tools::Copilot::SearchAvailableSlotsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_available_slots'
  end

  description 'Search appointment slots for one or more specialists using explicit specialist filters or a scheduling service'
  param :from, type: :string, desc: 'Range start datetime in ISO 8601 format', required: true
  param :to, type: :string, desc: 'Range end datetime in ISO 8601 format', required: true
  param :resource_ids, type: :array, desc: 'Optional list of specialist resource IDs', required: false
  param :service_id, type: :number, desc: 'Optional service ID used to filter specialists and derive slot duration', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes when no service is provided', required: false
  param :limit, type: :number, desc: 'Maximum number of slots to return', required: false

  def execute(from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil)
    payload = Scheduling::AvailableSlotSearchService.new(
      account: account,
      from: parse_datetime(from, field_name: 'from', required: true),
      to: parse_datetime(to, field_name: 'to', required: true),
      resource_ids: parse_id_list(resource_ids, field_name: 'resource_ids'),
      service_id: service_id,
      duration_min: duration_min,
      limit: limit
    ).perform

    formatted_payload(payload)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
