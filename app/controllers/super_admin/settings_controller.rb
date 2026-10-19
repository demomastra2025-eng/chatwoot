class SuperAdmin::SettingsController < SuperAdmin::ApplicationController
  helper SuperAdmin::AppConfigHelper

  def show; end

  # Asks the Hub of the vendor of the base for news. It does nothing, and says so, unless the installation opted in
  # (ENABLE_CHATWOOT_HUB_SYNC, see ChatwootHub.sync_enabled?).
  def refresh
    return redirect_to(super_admin_settings_path, notice: I18n.t('super_admin.settings.refresh_disabled')) unless ChatwootHub.sync_enabled?

    Internal::CheckNewVersionsJob.perform_now
    redirect_to super_admin_settings_path, notice: I18n.t('super_admin.settings.refreshed')
  end
end
