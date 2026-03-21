class Api::V1::Accounts::Integrations::HooksController < Api::V1::Accounts::BaseController
  before_action :fetch_hook, except: [:create]
  before_action :check_authorization

  def create
    @hook = Current.account.hooks.create!(normalized_params)
  end

  def update
    @hook.update!(normalized_params.slice(:status, :settings, :access_token))
  end

  def process_event
    response = @hook.process_event(params[:event])

    # for cases like an invalid event, or when conversation does not have enough messages
    # for a label suggestion, the response is nil
    if response.nil?
      render json: { message: nil }
    elsif response[:error]
      render json: { error: response[:error] }, status: :unprocessable_content
    else
      render json: { message: response[:message] }
    end
  end

  def destroy
    @hook.destroy!
    head :ok
  end

  private

  def fetch_hook
    @hook = Current.account.hooks.find(params[:id])
  end

  def check_authorization
    authorize(:hook)
  end

  def permitted_params
    params.require(:hook).permit(:app_id, :inbox_id, :status, :access_token, settings: {}, secret_settings: {})
  end

  def normalized_params
    params = permitted_params.to_h
    secret_settings = compact_secret_settings(params.delete('secret_settings'))

    if secret_settings.present?
      existing_secret_settings = @hook&.secret_settings || {}
      params['access_token'] = existing_secret_settings.merge(secret_settings).to_json
    end

    if [true, false, 'true', 'false'].include?(params['status'])
      params['status'] = ActiveModel::Type::Boolean.new.cast(params['status']) ? 'enabled' : 'disabled'
    end

    params.delete('access_token') if params['access_token'].blank?
    params
  end

  def compact_secret_settings(secret_settings)
    return {} if secret_settings.blank?

    secret_settings.to_h.transform_values { |value| value.is_a?(String) ? value.strip : value }.compact_blank
  end
end
