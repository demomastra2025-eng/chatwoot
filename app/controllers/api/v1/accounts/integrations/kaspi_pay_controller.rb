# frozen_string_literal: true

class Api::V1::Accounts::Integrations::KaspiPayController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def status
    verify_live = ActiveModel::Type::Boolean.new.cast(params[:verify])
    render json: auth_service.status_payload(verify_live: verify_live)
  end

  def send_otp
    result = auth_service.send_otp!(
      raw_phone: params[:phone_number],
      app_version: params[:app_version],
      app_build: params[:app_build]
    )
    render json: result
  rescue Integrations::KaspiPay::PhoneNormalizer::InvalidPhoneError,
         Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.try(:code) }, status: :unprocessable_content
  end

  def verify_otp
    result = auth_service.verify_otp!(
      process_id: params[:process_id],
      otp: params[:otp]
    )
    render json: result
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.code }, status: :unprocessable_content
  end

  def check_session
    check_res = auth_service.check_session!
    render json: auth_service.status_payload.merge(check: check_res)
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.code }, status: :unprocessable_content
  end

  def update_settings
    render json: auth_service.update_settings!(settings_params)
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.code }, status: :unprocessable_content
  end

  def disconnect
    render json: auth_service.disconnect!
  end

  private

  def auth_service
    @auth_service ||= Integrations::KaspiPay::AuthService.new(account: Current.account)
  end

  def settings_params
    params.permit(:auto_send_link_to_chat, :profile_id, :app_version, :app_build)
  end
end
