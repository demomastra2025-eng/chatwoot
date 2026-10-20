# frozen_string_literal: true

# «Больше не показывать» under the reminder about the second step of the sign-in on «Сводка», and the way back on the card of the
# user. Both are about the signed-in super admin himself: nobody hides or brings back the reminder of another one.
class SuperAdmin::TwoFactorNoticesController < SuperAdmin::ApplicationController
  def hide
    SuperAdmin::TwoFactorNotice.hide!(current_super_admin, request: request)
    redirect_to super_admin_root_path, notice: I18n.t('super_admin.two_factor.notice.hidden')
  end

  def restore
    SuperAdmin::TwoFactorNotice.restore!(current_super_admin, request: request)
    redirect_back fallback_location: super_admin_root_path, notice: I18n.t('super_admin.two_factor.notice.restored')
  end
end
