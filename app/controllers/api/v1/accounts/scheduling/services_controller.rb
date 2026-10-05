class Api::V1::Accounts::Scheduling::ServicesController < Api::V1::Accounts::Scheduling::BaseController
  COMPENSATION_KEYS = %i[compensation_type compensation_value compensation_percent].freeze

  before_action :check_admin_authorization?, except: [:index, :show]
  before_action :set_service, only: [:show, :update, :destroy]
  before_action :ensure_provider_writable_service!, only: [:update, :destroy]
  before_action :validate_provider_owned_attributes!, only: [:create, :update]

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

  def normalize_price_payload(item, service:)
    payload = item.to_h.symbolize_keys
    resource_id = payload[:resource_id].presence || payload[:employee_id].presence
    raise ArgumentError, 'resource_id is required for service prices' if resource_id.blank?

    active = payload.key?(:active) ? ActiveModel::Type::Boolean.new.cast(payload[:active]) : true
    price = payload[:price]
    price = service.base_price if active && price.blank?

    {
      resource: Current.account.scheduling_resources.not_deleted_from_scheduling.find(resource_id),
      price: normalize_integer_numeric_value(price, field_name: :price),
      active: active
    }.merge(compensation_payload(payload))
  end

  # The specialist rate is not edited in the UI any more, so a price row may omit it:
  # only the rate keys that were sent are applied and stored values stay untouched.
  def compensation_payload(payload)
    payload.slice(*COMPENSATION_KEYS).to_h do |key, value|
      [key, key == :compensation_type ? value : normalize_integer_numeric_value(value, field_name: key)]
    end
  end

  def normalize_integer_numeric_value(value, field_name:)
    Scheduling::IntegerNumericNormalizer.normalize_or_zero(value, field_name: field_name)
  end

  def price_payloads
    return nil unless params.key?(:prices) || params.key?(:employee_prices)

    raw_prices = params.permit(prices: [:resource_id, :price, :compensation_type, :compensation_value, :compensation_percent, :active],
                               employee_prices: [:employee_id, :price, :compensation_type, :compensation_value, :compensation_percent, :active])
    raw_prices[:prices] || raw_prices[:employee_prices] || []
  end

  def service_params
    normalize_integer_numeric_params!(
      params.permit(:name, :base_price, :duration_min, :category, :direction, :service_type, :description, :active, custom_attributes: {}),
      :base_price,
      :duration_min
    )
  end

  def set_service
    @service = Current.account.scheduling_services.includes(:prices).find(params[:id])
  end

  def validate_provider_owned_attributes!
    incoming = params.permit(custom_attributes: {})[:custom_attributes]
    Integrations::Medelement::ProviderOwnedAttributesGuard.validate!(
      incoming: incoming,
      current: @service&.custom_attributes
    )
  end

  def ensure_provider_writable_service!
    return if @service.custom_attributes.to_h['medelement_nomenclature_code'].blank?

    raise Scheduling::Error.new(
      code: 'SERVICE_READ_ONLY',
      message: 'Imported Medelement services are read-only because the provider API does not support service writes',
      status: :unprocessable_content
    )
  end

  def sync_prices!(service)
    payloads = price_payloads
    return if payloads.nil?

    keep_ids = []

    payloads.each do |item|
      attrs = normalize_price_payload(item, service: service)
      resource = attrs.delete(:resource)
      price = service.prices.find_or_initialize_by(resource: resource)
      # A new price starts from the specialist's own rate, as the form used to prefill it.
      price.assign_attributes(resource.slice(*COMPENSATION_KEYS)) if price.new_record?
      price.assign_attributes(attrs)
      price.save!
      keep_ids << price.id
    end

    service.prices.where.not(id: keep_ids.compact).destroy_all
  end
end
