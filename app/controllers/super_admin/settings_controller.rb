class SuperAdmin::SettingsController < SuperAdmin::ApplicationController
  helper SuperAdmin::AppConfigHelper

  def show; end

  def refresh
    Internal::CheckNewVersionsJob.perform_now
    redirect_to super_admin_settings_path, notice: I18n.t('super_admin.settings.refreshed')
  end
end
