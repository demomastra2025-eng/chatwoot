# frozen_string_literal: true

# What one bulk action does to an account (see SuperAdmin::BulkAccounts). A subclass answers:
#
#   evaluate(account) # => Entry: would the action change this account, or skip it (and why)? Writes nothing.
#   perform(account)  # => nil when the account was changed, or the reason (a symbol) when there was nothing to do after all
#
# and may ask for a setting first (`parameter?`: the modules to apply, the organization to link to): the confirmation
# page asks for it, and shows what would change only after it is chosen (`ready?`).
class SuperAdmin::BulkAccounts::Base
  attr_reader :actor, :request

  # options: what the request carried for this action; `:chosen` says the setting form was submitted
  def initialize(options: {}, actor: nil, request: nil)
    @options = options.to_h.symbolize_keys
    @actor = actor
    @request = request
  end

  # Whether the action needs a setting chosen first
  def parameter? = false

  # Whether the action can be previewed and run: everything it needs is chosen and valid
  def ready? = !parameter? || (chosen? && error.nil?)

  # Why the chosen setting is not valid (a key of super_admin.bulk.errors), nil when it is
  def error = nil

  # Whether the confirmation page warns about what the action does before it is confirmed
  def warning? = false

  def evaluate(_account) = raise(NotImplementedError)

  def perform(_account) = raise(NotImplementedError)

  private

  attr_reader :options

  def chosen? = ActiveModel::Type::Boolean.new.cast(options[:chosen]) ? true : false

  def change(account, detail = {})
    SuperAdmin::BulkAccounts::Entry.new(account_id: account.id, account: account, outcome: :change, reason: nil, detail: detail)
  end

  def skip(account, reason, detail = {})
    SuperAdmin::BulkAccounts::Entry.new(account_id: account.id, account: account, outcome: :skip, reason: reason, detail: detail)
  end

  def audit(account, action, changes)
    SuperAdmin::AccountAudit.record(
      account: account, actor: actor, action: action, changes: changes.merge(SuperAdmin::BulkAccounts::AUDIT_EXTRA), request: request
    )
  end
end
