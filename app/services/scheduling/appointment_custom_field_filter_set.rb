class Scheduling::AppointmentCustomFieldFilterSet < Crm::CustomFieldFilterSet
  def initialize(account:, raw_filters:)
    super(account: account, entity_kind: 'appointment', raw_filters: raw_filters)
  end
end
