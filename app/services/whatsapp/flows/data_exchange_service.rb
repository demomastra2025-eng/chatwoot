# frozen_string_literal: true

class Whatsapp::Flows::DataExchangeService
  SUPPORTED_ACTIONS = %w[ping INIT BACK data_exchange].freeze

  def initialize(channel:, payload:)
    @channel = channel
    @payload = payload.to_h.with_indifferent_access
  end

  def perform
    return { data: { status: 'active' } } if action == 'ping'
    return { data: { acknowledged: true } } if client_error_notification?

    token_check = Whatsapp::Flows::TokenService.verify_flow_token(payload[:flow_token], channel: channel)
    return invalid_token_response unless token_check[:valid] || token_check[:preview]

    dispatch_flow_handler(token_check)
  end

  private

  attr_reader :channel, :payload

  def action
    payload[:action].to_s
  end

  def client_error_notification?
    data = payload[:data]
    data.is_a?(Hash) && (data[:error].present? || data['error'].present?)
  end

  def dispatch_flow_handler(token_check)
    Whatsapp::Flows::BookingDataExchangeHandler.new(
      channel: channel,
      payload: payload,
      token_check: token_check
    ).perform
  end

  def invalid_token_response
    configured_locale = channel.provider_config.to_h.dig('whatsapp_flows', 'booking_locale')
    copy = Whatsapp::Flows::BookingFlowCopy.for_locale(configured_locale, account: channel.account)
    {
      screen: 'BOOKING_STEP',
      data: {
        has_error: true,
        error_message: copy[:flow_expired_error],
        show_services: false,
        services: [{ id: 'none', title: '-', description: '' }],
        specialists: [{ id: 'none', title: '-', description: '' }],
        dates: [{ id: Date.current.iso8601, title: Date.current.iso8601 }],
        init_service_id: 'none',
        init_resource_id: 'none',
        init_booking_date: Date.current.iso8601
      }
    }
  end
end
