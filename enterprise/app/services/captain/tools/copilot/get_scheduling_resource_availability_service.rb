class Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService < Captain::Tools::Copilot::BaseAccountTool
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS

  def self.name
    'get_scheduling_resource_availability'
  end

  description 'Get free specialist appointment windows inside a time range, with service-aware duration when available'
  param :resource_id, type: :number, desc: 'Specialist resource ID', required: true
  param :from, type: :string, desc: 'Range start datetime', required: true
  param :to, type: :string, desc: 'Range end datetime', required: true
  param :service_id, type: :number, desc: 'Optional service ID to derive appointment duration and validate specialist coverage', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes', required: false
  param :limit, type: :number, desc: 'Maximum number of slots to return', required: false

  def execute(resource_id:, from:, to:, service_id: nil, duration_min: nil, limit: nil)
    service_id = optional_positive_id(service_id)
    range_from = parse_datetime(from, field_name: 'from', required: true)
    range_to = parse_datetime(to, field_name: 'to', required: true)
    validate_range!(range_from, range_to)

    resource = find_resource!(resource_id)
    service_record = resolve_service_for_resource(resource: resource, service_id: service_id)
    payload = Scheduling::ResourceAvailabilityQueryService.new(
      resource: resource,
      from: range_from,
      to: range_to,
      service: service_record,
      duration_min: duration_min,
      limit: parse_limit(limit)
    ).perform

    formatted_payload(payload)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def find_resource!(resource_id)
    account.scheduling_resources.available_for_scheduling.find_by(id: resource_id).tap do |resource|
      raise ActiveRecord::RecordNotFound, 'Specialist not found' if resource.blank?
    end
  end

  def resolve_service_for_resource(resource:, service_id:)
    return nil if service_id.blank?

    service_record = account.scheduling_services.active.find_by(id: service_id)
    raise ActiveRecord::RecordNotFound, 'Service not found' if service_record.blank?

    active_price = resource.service_prices.active.find_by(service_id: service_record.id)
    raise ArgumentError, 'Service is not available for this specialist' if active_price.blank?

    service_record
  end

  def validate_range!(range_from, range_to)
    Scheduling::RangeValidator.validate!(from: range_from, to: range_to, max_days: MAX_RANGE_DAYS)
  end
end
