require 'administrate/base_dashboard'

class BillingAccountDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number.with_options(searchable: true),
    name: Field::String.with_options(searchable: true),
    status: Field::Select.with_options(collection: BillingAccount::STATUSES),
    default_currency: Field::String,
    default_locale: Field::String,
    payer_type: Field::Select.with_options(collection: ['', 'individual', 'business']),
    legal_name: Field::String,
    tax_id: Field::String,
    billing_contact_name: Field::String,
    billing_email: Field::String,
    billing_phone: Field::String,
    billing_address: Field::Text,
    billing_country: Field::String,
    workspaces: Field::HasMany,
    users: Field::HasMany,
    subscriptions: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id name status default_currency workspaces updated_at].freeze
  SHOW_PAGE_ATTRIBUTES = %i[
    id name status default_currency default_locale workspaces users subscriptions created_at updated_at
  ].freeze
  FORM_ATTRIBUTES = (%i[name status default_currency default_locale] + BillingAccount::PAYER_ATTRIBUTES.map(&:to_sym)).freeze
  COLLECTION_FILTERS = {
    active: ->(resources) { resources.active },
    suspended: ->(resources) { resources.suspended }
  }.freeze

  def display_resource(billing_account)
    "##{billing_account.id} #{billing_account.name}"
  end
end
