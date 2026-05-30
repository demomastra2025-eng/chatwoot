class CompanyPolicy < ApplicationPolicy
  def index?
    company_access?
  end

  def search?
    company_access?
  end

  def show?
    company_access?
  end

  def create?
    company_access?
  end

  def update?
    company_access?
  end

  def avatar?
    update?
  end

  def destroy_custom_attributes?
    update?
  end

  def destroy?
    companies_enabled? && administrator_access?
  end

  private

  def company_access?
    companies_enabled? && contact_access?
  end

  def companies_enabled?
    account&.feature_enabled?('companies')
  end
end
