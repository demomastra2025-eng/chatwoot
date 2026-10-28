# A specialist's recorded absence, including the reason and last local calendar day.
class Scheduling::TimeOffPayload
  def self.for(account:, resource_ids:, from:, to:)
    resources = account.scheduling_resources.where(id: resource_ids).index_by(&:id)
    account.scheduling_time_offs.where(resource_id: resources.keys)
           .where('starts_at < ? AND ends_at > ?', to, from).ordered.filter_map do |absence|
      resource = resources[absence.resource_id]
      payload(absence, resource) if resource
    end
  end

  def self.payload(absence, resource)
    zone = ActiveSupport::TimeZone[resource.timezone] || Time.zone
    { resource_id: resource.id, name: resource.name, kind: absence.kind,
      from: absence.starts_at.in_time_zone(zone).to_date.iso8601,
      through: (absence.ends_at - 1.second).in_time_zone(zone).to_date.iso8601,
      reason: absence.notes.presence || absence.title.presence }.compact
  end
  private_class_method :payload
end
