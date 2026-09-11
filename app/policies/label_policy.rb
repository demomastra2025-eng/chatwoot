class LabelPolicy < ApplicationPolicy
  def index?
    account_member_access?
  end

  def update?
    account_member_access?
  end

  def show?
    account_member_access?
  end

  def create?
    account_member_access?
  end

  def destroy?
    account_member_access?
  end

  private

  def account_member_access?
    account_user.present?
  end
end
