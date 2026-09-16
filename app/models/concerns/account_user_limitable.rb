module AccountUserLimitable
  extend ActiveSupport::Concern

  def countable_users_for_limits
    users.where.not(type: 'SuperAdmin').or(users.where(type: nil))
  end

  def user_countable_for_limits?(user)
    user.type != 'SuperAdmin'
  end
end
