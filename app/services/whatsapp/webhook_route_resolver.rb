class Whatsapp::WebhookRouteResolver
  def initialize(params:)
    @params = params.with_indifferent_access
  end

  def perform
    return route_channel unless @params[:object] == 'whatsapp_business_account'

    resolve_business_payload
  end

  private

  def resolve_business_payload
    payload_resolver = Whatsapp::WebhookChannelResolver.new(params: @params)
    payload_channel = payload_resolver.perform
    return payload_channel if route_channel.blank?

    resolve_explicit_route(payload_channel, payload_resolver)
  end

  def route_channel
    @route_channel ||= Channel::Whatsapp.find_by(phone_number: @params[:phone_number]) if @params[:phone_number].present?
  end

  def resolve_explicit_route(payload_channel, payload_resolver)
    return route_channel if payload_channel&.id == route_channel.id
    return route_channel if payload_resolver.matches_routing_metadata?(route_channel)
    return route_channel if allowed_coexistence_handoff_route?(payload_channel)
    return route_channel if allowed_metadata_free_explicit_route?(payload_channel)

    Rails.logger.error('[WHATSAPP_WEBHOOK] refused payload because callback phone conflicts with payload metadata')
    nil
  end

  def allowed_coexistence_handoff_route?(payload_channel)
    return false unless coexistence_field?
    return false unless cloud_handoff_channels?(payload_channel)
    return false unless standard_to_coexistence_handoff?(payload_channel)
    return false unless route_channel.account_id == payload_channel.account_id

    handoff_waba_matches?(payload_channel)
  end

  def cloud_handoff_channels?(payload_channel)
    route_channel.provider == 'whatsapp_cloud' && payload_channel&.provider == 'whatsapp_cloud'
  end

  def standard_to_coexistence_handoff?(payload_channel)
    route_flow = route_channel.provider_config.to_h['embedded_signup_flow']
    payload_flow = payload_channel.provider_config.to_h['embedded_signup_flow']
    route_flow != 'coexistence' && payload_flow == 'coexistence'
  end

  def handoff_waba_matches?(payload_channel)
    waba_ids = entry_waba_ids
    route_waba_id = route_channel.provider_config.to_h['business_account_id'].to_s
    payload_waba_id = payload_channel.provider_config.to_h['business_account_id'].to_s
    waba_ids.one? && route_waba_id == waba_ids.first && payload_waba_id == waba_ids.first
  end

  def allowed_metadata_free_explicit_route?(payload_channel)
    payload_channel.blank? && !routing_metadata_present? && webhook_fields.any?
  end

  def coexistence_field?
    %w[history smb_app_state_sync].include?(webhook_fields.first)
  end

  def routing_metadata_present?
    changes.any? do |change|
      metadata = change.dig(:value, :metadata).to_h
      metadata[:display_phone_number].present? || metadata[:phone_number_id].present?
    end
  end

  def entry_waba_ids
    Array(@params[:entry]).filter_map { |entry| entry[:id] }.map(&:to_s).uniq
  end

  def changes
    Array(@params[:entry]).flat_map { |entry| Array(entry[:changes]) }
  end

  def webhook_fields
    @webhook_fields ||= changes.filter_map { |change| change[:field] }.uniq
  end
end
