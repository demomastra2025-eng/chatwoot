# frozen_string_literal: true

module PlatformSupportContext
  private

  def pundit_user
    super.merge(super_admin_impersonation: @super_admin_impersonation)
  end
end
