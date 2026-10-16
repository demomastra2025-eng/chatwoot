require 'administrate/field/select'

# The «Организация» select of the account form: «Без организации» and the organizations by name. It posts the id (empty
# for no organization). AccountsController does not save it with the other fields: it links the account through
# SuperAdmin::OrganizationLinks, so the entries of the audit log name the super admin and say what moved.
class OrganizationSelectField < Administrate::Field::Select
  # The organization is not something the search box of the account list looks for (it would match the numbers)
  def self.searchable?
    false
  end

  def selectable_options
    [[I18n.t('super_admin.accounts.organization.none'), '']] + SuperAdmin::OrganizationOptions.for_select
  end
end
