# frozen_string_literal: true

# Links an account to an organization, moves it to another one or unlinks it, and leaves entries in the audit log on
# both sides: on the account (`link_organization` / `unlink_organization`) and on every organization that gained or
# lost it (`link_account` / `unlink_account`). Only the foreign key is written (no validations or callbacks of the
# account run), so an account with old data that no longer passes its validations can still be linked.
#
# The holder of the account is read again under a row lock (`SELECT ... FOR UPDATE` on the account), in the same
# transaction as the write, so two super admins working on the same account at once cannot both win. A page is drawn
# from an earlier state of the account, so the caller says who it expects to hold the account:
#
#   * `expected_holder: nil` (the card of an organization linking a free account): the account must still be free
#     (or already be there); an account that was linked elsewhere in the meantime is refused;
#   * `expected_holder: organization` (the card of an organization unlinking one of its accounts): the account must
#     still be linked to THAT organization;
#   * no `expected_holder` (the card and the edit form of the account itself): the account may be moved from wherever
#     it is.
#
# A refusal raises SuperAdmin::OrganizationLinks::Refused (it carries the organization that holds the account now, nil
# for a free account) and changes nothing. The audit entries are written after the commit from the state that was
# committed: `previous` is what the account really left, not what the page showed.
#
#   links = SuperAdmin::OrganizationLinks.new(actor: current_super_admin, request: request)
#   links.link(account: account, organization: organization, expected_holder: nil).changed? # false when it was there already
#   links.unlink(account: account, expected_holder: organization).previous                  # the organization it left
class SuperAdmin::OrganizationLinks
  ANY_HOLDER = Object.new.freeze

  # `changed?` is false when the account was already where it was asked to be; `previous` is the organization it held
  # before (nil for a free account)
  Result = Struct.new(:changed, :previous, keyword_init: true) do
    def changed? = changed
  end

  # The account is not where the caller expected it to be; `holder` is the organization that holds it now (nil: nobody)
  class Refused < StandardError
    attr_reader :holder

    def initialize(holder)
      @holder = holder
      super("the account is held by #{holder ? "organization #{holder.id}" : 'nobody'}")
    end
  end

  # audit_extra: more keys for the entry of the account in the audit log (a bulk action marks its entries with `'bulk' => true`)
  def initialize(actor: nil, request: nil, audit_extra: {})
    @actor = actor
    @request = request
    @audit_extra = audit_extra
  end

  def link(account:, organization:, expected_holder: ANY_HOLDER)
    previous = locked_change(account) do |holder|
      next holder if holder == organization # already there: nothing to write, nothing to refuse
      raise Refused, holder unless expected?(holder, expected_holder)

      write(account, organization)
      holder
    end
    return Result.new(changed: false, previous: organization) if previous == organization

    record_account_side(account, previous, organization)
    record_organization_side(previous, 'unlink_account', account)
    record_organization_side(organization, 'link_account', account)
    Result.new(changed: true, previous: previous)
  end

  def unlink(account:, expected_holder: ANY_HOLDER)
    previous = locked_change(account) do |holder|
      next holder if holder.nil? && expected_holder.equal?(ANY_HOLDER) # nothing to unlink
      raise Refused, holder unless expected?(holder, expected_holder)

      write(account, nil)
      holder
    end
    return Result.new(changed: false, previous: nil) if previous.nil?

    record_account_side(account, previous, nil)
    record_organization_side(previous, 'unlink_account', account)
    Result.new(changed: true, previous: previous)
  end

  private

  # Runs the block with the account locked and read again; the block gets the organization that holds it right now.
  # Returns what the block returned. The account in the caller's hands is refreshed from the locked row.
  def locked_change(account)
    Account.transaction do
      account.lock!
      yield account.organization
    end
  end

  def expected?(holder, expected_holder)
    expected_holder.equal?(ANY_HOLDER) || holder == expected_holder
  end

  def write(account, organization)
    account.update_columns(organization_id: organization&.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    account.association(:organization).reset
  end

  def record_account_side(account, previous, organization)
    SuperAdmin::AccountAudit.record(
      account: account, actor: @actor, request: @request,
      action: organization ? 'link_organization' : 'unlink_organization',
      changes: {
        'organization_id' => [previous&.id, organization&.id], 'organization_name' => [previous&.name, organization&.name]
      }.merge(@audit_extra)
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
