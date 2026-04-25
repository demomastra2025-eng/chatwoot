class Captain::Tools::Copilot::GetSchedulingResourceScheduleService < Captain::Tools::Copilot::BaseAccountTool
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS

  def self.name
    'get_scheduling_resource_schedule'
  end

  description 'Get the normalized working schedule of a specialist for a date range, including overrides, breaks, holidays, and time off'
  param :resource_id, type: :number, desc: 'Specialist resource ID', required: true
  param :from, type: :string, desc: 'Range start datetime', required: true
  param :to, type: :string, desc: 'Range end datetime', required: true
  param :include_breaks, type: :boolean, desc: 'Whether to include break intervals', required: false
  param :include_holidays, type: :boolean, desc: 'Whether to include holiday metadata', required: false
  param :include_time_offs, type: :boolean, desc: 'Whether to include time-off intervals', required: false

  def execute(resource_id:, from:, to:, include_breaks: true, include_holidays: true, include_time_offs: true)
    range_from = parse_datetime(from, field_name: 'from', required: true)
    range_to = parse_datetime(to, field_name: 'to', required: true)
    validate_range!(range_from, range_to)

    resource = find_resource!(resource_id)
    payload = Scheduling::ResourceScheduleService.new(
      resource: resource,
      from: range_from,
      to: range_to,
      include_breaks: include_breaks,
      include_holidays: include_holidays,
      include_time_offs: include_time_offs
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
    account.scheduling_resources.not_deleted_from_scheduling.find_by(id: resource_id).tap do |resource|
      raise ActiveRecord::RecordNotFound, 'Specialist not found' if resource.blank?
    end
  end

  def validate_range!(range_from, range_to)
    Scheduling::RangeValidator.validate!(from: range_from, to: range_to, max_days: MAX_RANGE_DAYS)
  end
end
