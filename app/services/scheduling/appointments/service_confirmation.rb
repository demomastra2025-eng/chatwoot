class Scheduling::Appointments::ServiceConfirmation
  def self.bookable?(service:, resource:)
    service&.active? && priced?(service, resource) && mapped?(service, resource)
  end

  def self.priced?(service, resource)
    price = service.prices.find_by(resource_id: resource.id)
    (price&.active? && price.price.to_i.positive?) || service.base_price.to_i.positive?
  end

  def self.mapped?(service, resource)
    resource.custom_attributes.to_h['medelement_specialist_code'].blank? ||
      service.custom_attributes.to_h['medelement_nomenclature_code'].present?
  end
end
