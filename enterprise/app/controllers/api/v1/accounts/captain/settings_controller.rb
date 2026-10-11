class Api::V1::Accounts::Captain::SettingsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    render json: Captain::AccountSettings.new(Current.account).value
  end

  def update
    render json: Captain::AccountSettings.new(Current.account).update!(settings_params)
  rescue Captain::AccountSettings::Invalid => e
    render json: { errors: e.errors }, status: :unprocessable_entity
  end

  private

  def settings_params
    params.permit!.to_h.except('controller', 'action', 'account_id', 'format')
  end
end
