module AccessControl::AccountLockable
  extend ActiveSupport::Concern

  private

  def lock_account_for_access_control
    account.lock! if account&.persisted?
  end
end
