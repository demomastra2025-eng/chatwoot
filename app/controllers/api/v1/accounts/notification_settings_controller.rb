class Api::V1::Accounts::NotificationSettingsController < Api::V1::Accounts::BaseController
  before_action :set_user, :load_notification_setting

  def show; end

  def update
    update_flags
    @notification_setting.save!
    render action: 'show'
  end

  private

  def set_user
    @user = current_user
  end

  def load_notification_setting
    @notification_setting = @user.notification_settings.find_or_create_by!(account_id: Current.account.id) do |setting|
      setting.selected_email_flags = []
      setting.selected_inbox_flags = NotificationSetting.default_inbox_flag_names
      setting.selected_push_flags = [:push_conversation_assignment]
    end
  end

  def notification_setting_params
    params.require(:notification_settings).permit(
      selected_email_flags: [],
      selected_inbox_flags: [],
      selected_push_flags: []
    )
  end

  def update_flags
    @notification_setting.selected_email_flags = notification_setting_params[:selected_email_flags]
    @notification_setting.selected_inbox_flags = notification_setting_params[:selected_inbox_flags]
    @notification_setting.selected_push_flags = notification_setting_params[:selected_push_flags]
  end
end
