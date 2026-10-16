require 'administrate/base_dashboard'

# The organizations of the super admin: the paying parent of accounts (requisites, BIN, contract).
# The list and the card draw their own tables (app/views/super_admin/organizations/); the attributes here decide what
# Administrate searches, sorts and puts into the forms.
class OrganizationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String.with_options(searchable: true),
    legal_name: Field::String.with_options(searchable: true),
    bin: Field::String.with_options(searchable: true),
    contract_number: Field::String,
    contract_date: Field::Date,
    billing_email: Field::String,
    phone: Field::String,
    address: Field::Text,
    notes: Field::Text,
    accounts: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # The list is searched by name, legal name or BIN (the searchable attributes above); only these columns can sort.
  COLLECTION_ATTRIBUTES = %i[id name bin created_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id name legal_name bin address phone billing_email contract_number contract_date notes accounts created_at updated_at
  ].freeze

  # The form in two sections; the keys are the legends (helpers.label.organization.<key>).
  FORM_SECTIONS = {
    section_requisites: %i[name legal_name bin address phone billing_email],
    section_contract: %i[contract_number contract_date notes]
  }.freeze
  FORM_ATTRIBUTES = FORM_SECTIONS.values.flatten.freeze
  FORM_ATTRIBUTES_NEW = FORM_SECTIONS
  FORM_ATTRIBUTES_EDIT = FORM_SECTIONS

  COLLECTION_FILTERS = {}.freeze

  def display_resource(organization)
    organization.name
  end
end
