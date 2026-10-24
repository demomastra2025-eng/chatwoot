# The length of one visit to a specialist, in minutes.
#
#   a requested length (a positive number) wins;
#   no service: the specialist's own slot length;
#   a local service: the service's own length, as the clinic set it;
#   a MedElement service: its duration_min is the column default (MedElement gives no length), so it is never used. The length is
#     the median length of the specialist's visits with that service (Scheduling::ResourceServiceStat), rounded up to a whole
#     number of the specialist's slots; with no such history it is the specialist's slot.
module Scheduling::VisitDuration
  module_function

  # stats: the usable stat of each specialist for the service, by resource id (see .stats_for); looked up one by one when omitted.
  def minutes(resource:, service:, requested: nil, stats: nil)
    requested_min = requested.to_i
    return requested_min if requested_min.positive?
    return slot_minutes(resource) if service.blank?
    return service.duration_min unless service.medelement_service?

    history_minutes(resource, service, stats)
  end

  # One query for several specialists: { resource_id => stat } of the pairs that count (auto or confirmed).
  def stats_for(service:, resource_ids:)
    return {} if service.blank? || !service.medelement_service? || resource_ids.blank?

    Scheduling::ResourceServiceStat.usable.where(service_id: service.id, resource_id: resource_ids).index_by(&:resource_id)
  end

  # A service inside an availability answer. A MedElement service has no length of its own (its duration_min is the column default),
  # so the answer shows the length of the visit, or none when the specialists differ.
  def service_payload(service, duration_min:)
    payload = Scheduling::PayloadBuilder.service(service, prices: [])
    return payload unless service.medelement_service?

    duration_min.present? ? payload.merge(duration_min: duration_min) : payload.except(:duration_min)
  end

  def slot_minutes(resource)
    [resource.slot_duration_min.to_i, Scheduling::Constants::MIN_DURATION_MINUTES].max
  end

  def history_minutes(resource, service, stats)
    slot = slot_minutes(resource)
    median = median_for(resource, service, stats)
    return slot if median.blank?

    (median.fdiv(slot).ceil * slot).clamp(slot, [slot, Scheduling::Constants::MAX_DURATION_MINUTES].max)
  end

  def median_for(resource, service, stats)
    stat = if stats
             stats[resource.id]
           else
             Scheduling::ResourceServiceStat.usable.find_by(resource_id: resource.id, service_id: service.id)
           end
    stat&.median_duration_min.presence
  end
end
