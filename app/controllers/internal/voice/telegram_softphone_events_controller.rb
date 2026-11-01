class Internal::Voice::TelegramSoftphoneEventsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  before_action :authenticate_callback_token!

  def create
    result = TelegramCalls::ClaimCoordinator.new(payload: event_payload).perform
    render json: result, status: :ok
  end

  private

  def authenticate_callback_token!
    expected = TelegramCalls::Config.callback_token
    provided = bearer_token
    return if expected.present? && provided.bytesize == expected.bytesize &&
              ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def bearer_token
    header = request.headers['Authorization'].to_s
    header.start_with?('Bearer ') ? header.delete_prefix('Bearer ').strip : ''
  end

  def event_payload
    raw = params.to_unsafe_h.except('controller', 'action', 'telegram_softphone_event')
    return raw unless raw['event'].present? && raw['data'].is_a?(Hash)

    raw['data'].merge('event_type' => raw['event'].to_s)
  end
end
