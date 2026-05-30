class ContactPolicy < ApplicationPolicy
  def index?
    contact_access?
  end

  def active?
    contact_access?
  end

  def import?
    administrator_access?
  end

  def export?
    administrator_access?
  end

  def search?
    contact_access?
  end

  def filter?
    contact_access?
  end

  def update?
    contact_access?
  end

  def contactable_inboxes?
    contact_access?
  end

  def destroy_custom_attributes?
    contact_access?
  end

  def show?
    contact_access?
  end

  def create?
    contact_access?
  end

  def avatar?
    contact_access?
  end

  def destroy?
    administrator_access?
  end
end
