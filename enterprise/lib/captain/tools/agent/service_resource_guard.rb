# frozen_string_literal: true

# Guards patient-facing slot searches against pairing a service with an incompatible explicit specialist (for example, passing
# the CT cabinet ID when searching slots for an MRI service). When a multi-specialist lookup includes both compatible and
# incompatible indexed specialists, incompatible ones are filtered out; when every requested specialist is incompatible, returns
# a retryable Scheduling::Error listing eligible_resources. Newly added specialists with zero recorded services are allowed.
module Captain::Tools::Agent::ServiceResourceGuard
  module_function

  def resolve(account:, search_params:)
    service_id = search_params[:service_id]
    requested_ids = Scheduling::AvailableSlotSearchService.normalize_resource_ids(search_params[:resource_ids])
    return [search_params, nil] if service_id.blank? || requested_ids.blank?

    bookable = account.scheduling_resources.available_for_scheduling
    return [search_params, nil] unless all_bookable?(bookable, requested_ids)

    eligible = eligible_resources(account, service_id, bookable)
    return [search_params, nil] if eligible.empty?

    narrow_or_error(account, search_params, service_id, requested_ids, eligible)
  end

  def error(account:, search_params:)
    resolve(account: account, search_params: search_params).last
  end

  def all_bookable?(bookable, requested_ids)
    bookable.where(id: requested_ids).count == requested_ids.size
  end
  private_class_method :all_bookable?

  def eligible_resources(account, service_id, bookable)
    price_ids = Scheduling::ServicePrice.active.where(account_id: account.id, service_id: service_id).select(:resource_id)
    stat_ids = Scheduling::ResourceServiceStat.usable.where(account_id: account.id, service_id: service_id).select(:resource_id)
    bookable.where(id: price_ids).or(bookable.where(id: stat_ids)).ordered.to_a
  end
  private_class_method :eligible_resources

  def narrow_or_error(account, search_params, service_id, requested_ids, eligible)
    eligible_ids = eligible.map(&:id)
    mismatched_ids = requested_ids - eligible_ids
    return [search_params, nil] if mismatched_ids.empty?

    blocked_ids = mismatched_ids.select { |resource_id| enforced_for_resource?(account, service_id, resource_id) }
    return [search_params, nil] if blocked_ids.empty?

    kept_ids = requested_ids - blocked_ids
    return [search_params.merge(resource_ids: kept_ids), nil] if kept_ids.any?

    [search_params, build_error(service_id, requested_ids, eligible)]
  end
  private_class_method :narrow_or_error

  def enforced_for_resource?(account, service_id, resource_id)
    disabled_price?(account, service_id, resource_id) ||
      disabled_stat?(account, service_id, resource_id) ||
      indexed_resource?(account, resource_id)
  end
  private_class_method :enforced_for_resource?

  def disabled_price?(account, service_id, resource_id)
    Scheduling::ServicePrice.exists?(
      account_id: account.id, service_id: service_id, resource_id: resource_id, active: false
    )
  end
  private_class_method :disabled_price?

  def disabled_stat?(account, service_id, resource_id)
    Scheduling::ResourceServiceStat.exists?(
      account_id: account.id, service_id: service_id, resource_id: resource_id,
      status: Scheduling::ResourceServiceStat::STATUS_DISABLED
    )
  end
  private_class_method :disabled_stat?

  def indexed_resource?(account, resource_id)
    Scheduling::ServicePrice.active.exists?(account_id: account.id, resource_id: resource_id) ||
      Scheduling::ResourceServiceStat.usable.exists?(account_id: account.id, resource_id: resource_id)
  end
  private_class_method :indexed_resource?

  def build_error(service_id, requested_ids, eligible)
    eligible_list = eligible.map { |resource| { id: resource.id, name: resource.name } }
    summary = eligible_list.map { |item| "#{item[:id]} (#{item[:name]})" }.join(', ')
    message = "Requested resource_ids #{requested_ids.inspect} do not perform service_id #{service_id}. " \
              "Call search_available_slots again with resource_ids from eligible_resources: #{summary}."
    Scheduling::Error.new(
      code: 'SERVICE_RESOURCE_MISMATCH', status: :unprocessable_content, message: message,
      details: { reason: 'service_resource_mismatch', service_id: service_id,
                 requested_resource_ids: requested_ids, eligible_resources: eligible_list }
    )
  end
  private_class_method :build_error
end
