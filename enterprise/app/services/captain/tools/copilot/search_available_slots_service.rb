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
    service_id = optional_positive_id(service_id)
    payload = Scheduling::AvailableSlotSearchService.new(
      account: account,
      from: parse_datetime(from, field_name: 'from', required: true),
      to: parse_datetime(to, field_name: 'to', required: true),
      resource_ids: parse_id_list(resource_ids, field_name: 'resource_ids'),
      service_id: service_id,
      duration_min: duration_min,
      limit: limit
    ).perform
    publish_service_match(payload)

    formatted_payload(payload)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def publish_service_match(payload)
    match = payload.fetch(:service_match)
    event_name = match.fetch(:confirmed) ? 'captain.service_match_confirmed' : 'captain.service_match_missing'
    Llm::EventBus.publish(
      event_name,
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: account.id,
      conversation_id: current_conversation&.id,
      service_id: payload[:requested_service_id],
      resource_ids: match[:resource_ids]
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Scheduling] Failed to publish service match: #{e.class}: #{e.message}")
  end
end
