# The production availability engine accepts records, so session snapshots only
# adapt its record interface. All interval, holiday, break and conflict rules
# remain in Scheduling::AvailabilityService.
class Captain::Playground::AvailabilitySnapshot
  class Rules < Array
    def active = self
  end
  Resource = Struct.new(:id, :timezone, :work_rules, :break_rules, :account, keyword_init: true)
  Rule = Struct.new(:weekday, :start_minute, :end_minute, :title, keyword_init: true)
  Override = Struct.new(:date, :start_minute, :end_minute, :break_start_minute, :break_end_minute, :break_title, keyword_init: true)
  Interval = Struct.new(:id, :starts_at, :ends_at, :status, :title, :kind, :source, :custom_attributes, :external_ref, keyword_init: true)
  Holiday = Struct.new(:date, :recurring_yearly, :working_day_override, :title, keyword_init: true) do
    def recurring_yearly? = recurring_yearly == true
    def working_day_override? = working_day_override == true
  end

  def self.build(resource:, appointments:, from:, to:, ignore_appointment_id: nil)
    new(resource, appointments).build(from: from, to: to, ignore_appointment_id: ignore_appointment_id)
  end

  def initialize(resource, appointments)
    @resource, @appointments = resource, appointments
  end

  def build(from:, to:, ignore_appointment_id: nil)
    resource = adapted_resource
    Scheduling::AvailabilityService.new(
      resource: resource, from: from, to: to, ignore_appointment_id: ignore_appointment_id,
      holidays: Array(@resource['holidays']).map { |item| Holiday.new(**dated(item).slice(*Holiday.members)) },
      workday_overrides: Array(@resource['workday_overrides']).map { |item| Override.new(**dated(item).slice(*Override.members)) },
      time_offs: Array(@resource['time_offs']).map { |item| Interval.new(**timed(item)) },
      appointments: @appointments.select { |item| item['resource_id'] == resource.id }
                                 .map { |item| Interval.new(**timed(item).slice(:id, :starts_at, :ends_at, :status, :source, :custom_attributes, :external_ref)) }
    )
  end

  def schedule(from:, to:, **options)
    Scheduling::ResourceScheduleService.new(
      resource: adapted_resource, from: from, to: to, resource_payload: @resource.deep_dup,
      snapshots: {
        holidays: Array(@resource['holidays']).map { |item| Holiday.new(**dated(item).slice(*Holiday.members)) },
        workday_overrides: Array(@resource['workday_overrides']).map { |item| Override.new(**dated(item).slice(*Override.members)) },
        time_offs: Array(@resource['time_offs']).map { |item| Interval.new(**timed(item)) }
      }, **options
    ).perform
  end

  private

  def adapted_resource
    Resource.new(id: @resource.fetch('id'), timezone: @resource.fetch('timezone'),
                 work_rules: rules('work_rules'), break_rules: rules('break_rules'))
  end

  def rules(key)
    Rules.new(Array(@resource[key]).reject { |item| item['active'] == false }
                                 .map { |item| Rule.new(**item.symbolize_keys.slice(*Rule.members)) })
  end

  def dated(item)
    item.symbolize_keys.merge(date: Date.iso8601(item.fetch('date')))
  end

  def timed(item)
    item.symbolize_keys.slice(:id, :status, :title, :kind, :source, :external_ref).merge(
      starts_at: Time.iso8601(item.fetch('starts_at')), ends_at: Time.iso8601(item.fetch('ends_at')), custom_attributes: item.fetch('custom_attributes', {}))
  end
end
