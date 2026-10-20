# frozen_string_literal: true

# What the question before deleting a user (or taking one out of an account) has to say besides the name: in how many
# accounts the person is, and in which of them the person is the ONLY administrator (those accounts are left without
# one). Read for a whole page of the list with three queries, not three per row.
#
#   notes = SuperAdmin::UserRemovalNotes.for(users)   # users: a list of User
#   notes[user.id].accounts       # => 2
#   notes[user.id].sole_admin_in  # => ["Аккаунт Алатау"]
#   SuperAdmin::UserRemovalNotes.sole_administrator?(membership) # => true / false (one membership)
class SuperAdmin::UserRemovalNotes
  Note = Struct.new(:accounts, :sole_admin_in, keyword_init: true)
  EMPTY = Note.new(accounts: 0, sole_admin_in: []).freeze

  # { user id => Note } for every user of the list (a user without accounts has the empty note)
  def self.for(users)
    ids = Array(users).map(&:id)
    return {} if ids.empty?

    counts = AccountUser.where(user_id: ids).group(:user_id).count
    sole = sole_admin_accounts(ids)
    ids.index_with { |id| Note.new(accounts: counts.fetch(id, 0), sole_admin_in: sole.fetch(id, [])) }
  end

  # Whether the membership is the only administrator of its account
  def self.sole_administrator?(membership)
    membership.administrator? && AccountUser.administrator.where(account_id: membership.account_id).count == 1
  end

  # { user id => [names of the accounts where the user is the only administrator] }
  def self.sole_admin_accounts(user_ids)
    memberships = AccountUser.administrator.where(user_id: user_ids).includes(:account).to_a
    return {} if memberships.empty?

    admins = AccountUser.administrator.where(account_id: memberships.map(&:account_id)).group(:account_id).count
    memberships.select { |membership| admins[membership.account_id] == 1 }
               .group_by(&:user_id).transform_values { |list| list.map { |membership| membership.account.name } }
  end
  private_class_method :sole_admin_accounts
end
