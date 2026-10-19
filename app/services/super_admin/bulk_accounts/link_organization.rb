# frozen_string_literal: true

# Links the accounts to the chosen organization, moving the ones that belong to another, or (with «Без организации»)
# unlinks them. It goes through SuperAdmin::OrganizationLinks, which writes the entries of the audit log on both sides.
# An account that is already where it is asked to be is skipped.
#
# The setting is explicit: an organization number, or the word `none` for «Без организации». A request that does not say
# (no `organization_id`) is invalid, so a forgotten field never unlinks anybody.
class SuperAdmin::BulkAccounts::LinkOrganization < SuperAdmin::BulkAccounts::Base
  NONE = 'none'

  def parameter? = true

  # The organization the accounts go to: an Organization, :none for «Без организации», nil when the setting is missing or
  # names an organization that does not exist
  def target
    return @target if defined?(@target)

    value = options[:organization_id].is_a?(String) ? options[:organization_id].strip : nil
    @target = if value == NONE then :none
              elsif value&.match?(/\A\d{1,18}\z/) then Organization.find_by(id: value)
              end
  end

  def error = (:unknown_organization if target.nil?)

  def evaluate(account)
    holder = account.organization
    return skip(account, :already_free) if target == :none && holder.nil?
    return skip(account, :already_there) if target != :none && holder == target

    change(account, from: holder, to: (target unless target == :none))
  end

  def perform(account)
    links = SuperAdmin::OrganizationLinks.new(actor: actor, request: request, audit_extra: SuperAdmin::BulkAccounts::AUDIT_EXTRA)
    result = target == :none ? links.unlink(account: account) : links.link(account: account, organization: target)
    return if result.changed?

    target == :none ? :already_free : :already_there
  end
end
