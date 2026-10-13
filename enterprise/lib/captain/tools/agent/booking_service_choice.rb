# The service of a booking whose call named none. A specialist who offers no service is booked without one, exactly as before; a
# specialist who offers one service gets it; a specialist who offers several is a business answer that lists them (ID and name), so
# the agent picks by the patient's words or asks the patient.
#
# A specialist offers a service when an active price row links them and the service can be priced: the row's price or the service's
# base price is above zero, the rule by which the calendar accepts the booking (see Scheduling::Appointments::UpsertService).
class Captain::Tools::Agent::BookingServiceChoice
  MAX_LISTED = 10

  def initialize(account:, resource_id:)
    @account = account
    @resource_id = resource_id
  end

  # The Scheduling::Service to book, or nil when the specialist offers none. Raises the SERVICE_REQUIRED business answer when several.
  def perform
    services = offered_services
    return services.first if services.size <= 1

    details = { mutation_executed: false, services: services.first(MAX_LISTED).map { |service| { id: service.id, name: service.name } } }
    details[:more] = services.size - MAX_LISTED if services.size > MAX_LISTED
    raise Scheduling::Error.new(code: Captain::Tools::Agent::AppointmentResult::SERVICE_REQUIRED_CODE,
                                message: 'The specialist offers several services', status: :unprocessable_content, details: details)
  end

  private

  attr_reader :account, :resource_id

  def offered_services
    prices = account.scheduling_service_prices.active.where(resource_id: resource_id).includes(:service)
    prices.filter_map { |price| price.service if priceable?(price) }.uniq.sort_by { |service| [service.name.to_s, service.id] }
  end

  def priceable?(price)
    service = price.service
    return false unless service&.active? && service.account_id == account.id

    price.price.to_i.positive? || service.base_price.to_i.positive?
  end
end
