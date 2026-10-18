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
    accounts.count
  end

  def users_count
    users.count
  end

  private

  def permissible_ids(type)
    platform_app_permissibles.where(permissible_type: type).select(:permissible_id)
  end
end
