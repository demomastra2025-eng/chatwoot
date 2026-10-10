class Captain::Tools::Copilot::SearchAvailableSlotsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_available_slots'
  end

  description 'Search free appointment slots using local rules or confirmed stored MedElement hours. Returned slots can be offered; ' \
              'creation checks availability again. Service link metadata describes recorded price links; ' \
              'total_slots counts only the returned slots'
  param :from, type: :string, desc: 'Range start datetime in ISO 8601 format', required: true
  param :to, type: :string, desc: 'Range end datetime in ISO 8601 format', required: true
  param :resource_ids, type: :array, desc: 'Optional list of scheduling resource IDs', required: false
  param :service_id, type: :number, desc: 'Optional service ID to filter price links and derive duration', required: false
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
  rescue Scheduling::AvailableSlotSearchService::MissingServiceLinkError => e
    tool_failure(ArgumentError.new("#{e.message}: no recorded service-price link for these resources; provider eligibility is unverified"))
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
