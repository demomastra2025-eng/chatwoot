# == Schema Information
#
# Table name: platform_apps
#
#  id         :bigint           not null, primary key
#  name       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class PlatformApp < ApplicationRecord
  include AccessTokenable

  validates :name, presence: true

  has_many :platform_app_permissibles, dependent: :destroy_async

  # The partners with the number of their accounts and users counted in the same query, so a list of partners does not
  # ask the database twice for every row (`accounts_count` and `users_count` use these columns when they are there)
  def self.with_counts
    select(
      'platform_apps.*',
      "(#{count_of_permissibles('Account', 'accounts')}) AS accounts_total",
      "(#{count_of_permissibles('User', 'users')}) AS users_total"
    )
  end

  # The SQL that counts the records of one table the partner owns (only records that still exist, like #accounts)
  def self.count_of_permissibles(type, table)
    "SELECT COUNT(*) FROM platform_app_permissibles ppp INNER JOIN #{table} ON #{table}.id = ppp.permissible_id " \
      "WHERE ppp.platform_app_id = platform_apps.id AND ppp.permissible_type = '#{type}'"
  end
  private_class_method :count_of_permissibles

  # The accounts this partner created through the Platform API (the card of the partner lists them)
  def accounts
    Account.where(id: permissible_ids('Account'))
  end

  # The users this partner created through the Platform API. A SuperAdmin is stored as a plain 'User' permissible.
  def users
    User.where(id: permissible_ids('User'))
  end

  # True when the partner created this account or user: only those can be read or changed with its token
  def owns?(record)
    record.present? && platform_app_permissibles.exists?(permissible: record)
  end

  # The last characters of the token, for the list and the card (the token itself is shown once)
  def token_hint
    access_token&.hint
  end

  def accounts_count
    has_attribute?(:accounts_total) ? self[:accounts_total].to_i : accounts.count
  end

  def users_count
    has_attribute?(:users_total) ? self[:users_total].to_i : users.count
  end

  private

  def permissible_ids(type)
    platform_app_permissibles.where(permissible_type: type).select(:permissible_id)
  end
end
