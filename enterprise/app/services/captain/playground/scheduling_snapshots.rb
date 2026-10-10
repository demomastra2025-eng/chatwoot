# Snapshot records implement the production catalog and availability interfaces.
# They are never saved, and no provider identifiers are copied into this catalog.
class Captain::Playground::SchedulingSnapshots
  def initialize(data)
    @data = data
  end

  def resources
    @resources ||= @data.fetch('resources').select { |item| item['active'] }.sort_by { |item| [item['name'].to_s, item['id']] }.map do |item|
      Scheduling::Resource.new(item.slice('id', 'name', 'timezone', 'specialty', 'active', 'slot_duration_min').merge('custom_attributes' => {}))
    end
  end

  def service(id)
    return if id.blank?

    item = @data.fetch('services').find { |record| record['id'] == id && record['active'] }
    raise ActiveRecord::RecordNotFound, 'Service not found' unless item

    Scheduling::Service.new(item.slice('id', 'name', 'duration_min', 'active').merge('base_price' => item['amount'] || 0, 'custom_attributes' => {}))
  end

  def linked_resource_ids(service_id)
    @data.fetch('resources').select { |item| Array(item['service_ids']).include?(service_id) }.pluck('id')
  end

  def availability(resource:, from:, to:, **options)
    snapshot = @data.fetch('resources').find { |item| item['id'] == resource.id }
    engine = Captain::Playground::AvailabilitySnapshot.build(resource: snapshot, appointments: @data.fetch('appointments'), from: from, to: to)
    Scheduling::ResourceAvailabilityQueryService.new(resource: resource, from: from, to: to, availability_service: engine, **options).perform
  end

  def schedule(resource_id:, from:, to:, **options)
    resource = @data.fetch('resources').find { |item| item['id'] == resource_id }
    raise ActiveRecord::RecordNotFound, 'Specialist not found' unless resource

    Captain::Playground::AvailabilitySnapshot.new(resource, @data.fetch('appointments')).schedule(from: from, to: to, **options)
  end
end
