# frozen_string_literal: true

# Who from the super admins entered an account as one of its users, and when: the last LIMIT entries «impersonate» of the
# audit log (SuperAdmin::ImpersonationService leaves one each time a sign-in is issued), for the card of an account or the
# card of a user.
#
#   SuperAdmin::ImpersonationHistory.for_account(account) # every user of the account
#   SuperAdmin::ImpersonationHistory.for_user(user)       # this user, in each of their accounts
#
# The names are read for the whole list at once, so the cost does not depend on the number of entries. A person or an
# account that has been deleted since is still shown by the e-mail and the number the entry kept.
class SuperAdmin::ImpersonationHistory
  LIMIT = 20
  ACTION = 'impersonate'

  # at: when; actor: the super admin (name, id); as_user: the user entered as (label, id, whether the user still exists);
  # account: the account entered (name, id)
  Entry = Struct.new(:at, :actor_name, :actor_id, :user_label, :user_id, :user_known, :account_name, :account_id, keyword_init: true)

  def self.for_account(account)
    new(audits_scope.where(auditable_id: account.id)).entries
  end

  # The accounts the user belongs to NOW: the entries of an account are found by its number (an indexed read), and only then
  # by the user they name. An entry into an account the user has left since stays on the card of that account but is not
  # found here (the audit log has no index on the user, so the other way would read the whole log); the page says so.
  def self.for_user(user)
    account_ids = AccountUser.where(user_id: user.id).pluck(:account_id)
    return [] if account_ids.empty?

    scope = audits_scope.where(auditable_id: account_ids).where("audited_changes ->> 'impersonated_user_id' = ?", user.id.to_s)
    new(scope).entries
  end

  def self.audits_scope
    Audited::Audit.where(auditable_type: 'Account', action: ACTION).order(created_at: :desc, id: :desc).limit(LIMIT).includes(:user)
  end

  def initialize(scope)
    @audits = scope.to_a
  end

  def entries
    return [] if @audits.empty?

    users = User.where(id: @audits.filter_map { |audit| target_id(audit) }).pluck(:id, :name, :email).to_h { |id, name, email| [id, [name, email]] }
    accounts = Account.where(id: @audits.map(&:auditable_id)).pluck(:id, :name).to_h
    @audits.map { |audit| entry(audit, users, accounts) }
  end

  private

  def target_id(audit)
    Integer(audit.audited_changes.to_h['impersonated_user_id'].to_s, 10, exception: false)
  end

  def entry(audit, users, accounts)
    user_id = target_id(audit)
    name, email = users[user_id]
    Entry.new(
      at: audit.created_at, actor_name: actor_name(audit), actor_id: audit.user_id,
      user_label: [name, email || audit.audited_changes.to_h['impersonated_email']].compact_blank.uniq.join(' · '), user_id: user_id,
      user_known: users.key?(user_id), account_name: accounts[audit.auditable_id], account_id: audit.auditable_id
    )
  end

  def actor_name(audit)
    audit.user.try(:name).presence || audit.username.presence
  end
end
