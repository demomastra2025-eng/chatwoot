# frozen_string_literal: true

# Links an account to an organization, moves it to another one or unlinks it, and leaves entries in the audit log on
# both sides: on the account (`link_organization` / `unlink_organization`) and on every organization that gained or
# lost it (`link_account` / `unlink_account`). Only the foreign key is written (no validations or callbacks of the
# account run), so an account with old data that no longer passes its validations can still be linked.
#
#   links = SuperAdmin::OrganizationLinks.new(actor: current_super_admin, request: request)
#   links.link(account: account, organization: organization) # => true, false when it already belongs there
#   links.unlink(account: account)                           # => true, false when it had no organization
class SuperAdmin::OrganizationLinks
  def initialize(actor: nil, request: nil)
    @actor = actor
    @request = request
  end

  def link(account:, organization:)
    previous = account.organization
    return false if previous == organization

    write(account, organization)
    record_account_side(account, previous, organization)
    record_organization_side(previous, 'unlink_account', account)
    record_organization_side(organization, 'link_account', account)
    true
  end

  def unlink(account:)
    previous = account.organization
    return false if previous.nil?

    write(account, nil)
    record_account_side(account, previous, nil)
    record_organization_side(previous, 'unlink_account', account)
    true
  end

  private

  def write(account, organization)
    account.update_columns(organization_id: organization&.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    account.association(:organization).reset
  end

  def record_account_side(account, previous, organization)
    SuperAdmin::AccountAudit.record(
      account: account, actor: @actor, request: @request,
      action: organization ? 'link_organization' : 'unlink_organization',
      changes: { 'organization_id' => [previous&.id, organization&.id], 'organization_name' => [previous&.name, organization&.name] }
    )
  end

  def record_organization_side(organization, action, account)
    return if organization.nil?

    SuperAdmin::PlatformAudit.record(
      auditable: organization, action: action, actor: @actor, request: @request,
      changes: { 'account_id' => account.id, 'account_name' => account.name }
    )
  end
end
