# The service of a booking whose call named none. A specialist who offers none or several is booked without a service.
#
# A specialist offers a service when an active price row links them and the service can be priced: the row's price or the service's
# base price is above zero, the rule by which the calendar accepts the booking (see Scheduling::Appointments::UpsertService).
class Captain::Tools::Agent::BookingServiceChoice
  def initialize(account:, resource_id:)
    @account = account
    @resource_id = resource_id
  end

  # The sole Scheduling::Service to book, or nil when the specialist offers none or several.
  def perform
    services = offered_services
    services.first if services.one?
  end

  private

  attr_reader :account, :resource_id

  def offered_services
    prices = account.scheduling_service_prices.active.where(resource_id: resource_id).includes(:service)
    prices.filter_map { |price| price.service if priceable?(price) }.uniq
  end

  def priceable?(price)
    service = price.service
    return false unless service&.active? && service.account_id == account.id

    price.price.to_i.positive? || service.base_price.to_i.positive?
  end
end
