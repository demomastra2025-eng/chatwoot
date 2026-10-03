class SuperAdmin::SettingsController < SuperAdmin::ApplicationController
  def show; end

  def refresh
    Internal::CheckNewVersionsJob.perform_now
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_to super_admin_settings_path, notice: 'Статус инстанса успешно обновлен'
    # rubocop:enable Rails/I18nLocaleTexts
  end
end
