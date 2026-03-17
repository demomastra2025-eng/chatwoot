class Api::V1::Accounts::Scheduling::ServicesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, except: [:index, :show]
  before_action :set_service, only: [:show, :update, :destroy]

  def index
    services = Current.account.scheduling_services.includes(:prices).ordered
    services = services.active unless parse_boolean(params[:include_inactive])

    render_payload(
      services.map { |service| Scheduling::PayloadBuilder.service(service) },
      meta: { count: services.size }
    )
  end

  def show
    render_payload(Scheduling::PayloadBuilder.service(@service))
  end

  def create
    service = Current.account.scheduling_services.new(service_params)

    ApplicationRecord.transaction do
      service.save!
      sync_prices!(service)
    end

    render_payload(Scheduling::PayloadBuilder.service(service.reload), status: :created)
  end

  def update
    ApplicationRecord.transaction do
      @service.update!(service_params)
      sync_prices!(@service)
    end

    render_payload(Scheduling::PayloadBuilder.service(@service.reload))
  end

  def destroy
    @service.destroy!
    head :no_content
  end

  private

  def normalize_price_payload(item)
    payload = item.to_h.symbolize_keys
    resource_id = payload[:resource_id].presence || payload[:employee_id].presence
    raise ArgumentError, 'resource_id is required for service prices' if resource_id.blank?

    {
      resource: Current.account.scheduling_resources.find(resource_id),
      price: payload[:price],
      compensation_type: payload[:compensation_type],
      compensation_value: payload[:compensation_value],
      compensation_percent: payload[:compensation_percent],
      active: payload.key?(:active) ? payload[:active] : true
    }
  end

  def price_payloads
    return nil unless params.key?(:prices) || params.key?(:employee_prices)

    raw_prices = params.permit(prices: [:resource_id, :price, :compensation_type, :compensation_value, :compensation_percent, :active],
                               employee_prices: [:employee_id, :price, :compensation_type, :compensation_value, :compensation_percent, :active])
    raw_prices[:prices] || raw_prices[:employee_prices] || []
  end

  def service_params
    params.permit(:name, :base_price, :duration_min, :category, :direction, :service_type, :description, :active, custom_attributes: {})
  end

  def set_service
    @service = Current.account.scheduling_services.includes(:prices).find(params[:id])
  end

  def sync_prices!(service)
    payloads = price_payloads
    return if payloads.nil?

    keep_ids = []

    payloads.each do |item|
      attrs = normalize_price_payload(item)
      price = service.prices.find_or_initialize_by(resource: attrs.delete(:resource))
      price.assign_attributes(attrs)
      price.save!
      keep_ids << price.id
    end

    service.prices.where.not(id: keep_ids.compact).destroy_all
  end
end
