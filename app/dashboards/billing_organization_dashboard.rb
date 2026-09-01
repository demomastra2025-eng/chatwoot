require 'administrate/base_dashboard'

class BillingOrganizationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String.with_options(searchable: true),
    status: Field::Select.with_options(collection: [%w[Active active], %w[Suspended suspended]]),
    accounts: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    status
    accounts
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    status
    accounts
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    name
    status
  ].freeze

  COLLECTION_FILTERS = {
    active: ->(resources) { resources.where(status: :active) },
    suspended: ->(resources) { resources.where(status: :suspended) }
  }.freeze

  def display_resource(billing_organization)
    "##{billing_organization.id} #{billing_organization.name}"
  end
end
