module Whatsapp::TemplateInteractiveComponentHelpers
  include Whatsapp::TemplateCarouselComponentHelpers

  AUTHENTICATION_CATEGORY = 'AUTHENTICATION'.freeze
  CAROUSEL_COMPONENT_TYPE = 'CAROUSEL'.freeze
  CATALOG_BUTTON_TYPE = 'CATALOG'.freeze
  FLOW_BUTTON_TYPE = 'FLOW'.freeze

  private

  def process_interactive_components(template, processed_params)
    return process_authentication_button(processed_params) if authentication_template?(template)
    return process_carousel_component(template, processed_params) if carousel_template?(template)
    return process_catalog_button(template, processed_params) if catalog_template?(template)

    components = process_button_components(processed_params)
    ensure_signed_flow_button_tokens!(template, components)
    components.concat(process_auto_flow_buttons(template, components))
    components
  end

  def authentication_template?(template)
    template['category'].to_s.upcase == AUTHENTICATION_CATEGORY
  end

  def carousel_template?(template)
    template_component(template, CAROUSEL_COMPONENT_TYPE).present?
  end

  def catalog_template?(template)
    buttons_component = template_component(template, 'BUTTONS')
    Array(buttons_component&.[]('buttons')).any? { |button| button['type'].to_s.upcase == CATALOG_BUTTON_TYPE }
  end

  def process_authentication_button(processed_params)
    otp = processed_params['body']&.values&.first.to_s.strip
    raise ArgumentError, 'Authentication template OTP is required' if otp.blank?
    raise ArgumentError, 'Authentication template OTP cannot exceed 15 characters' if otp.length > 15

    [{
      type: 'button',
      # Meta's send-message contract uses URL subtype for OTP buttons, including templates created with otp_type=COPY_CODE.
      sub_type: 'url',
      index: 0,
      parameters: [{ type: 'text', text: otp }]
    }]
  end

  def process_catalog_button(template, processed_params)
    retailer_id = processed_params.dig('catalog', 'thumbnail_product_retailer_id').to_s.strip
    return [] if retailer_id.blank?

    buttons = Array(template_component(template, 'BUTTONS')&.[]('buttons'))
    button_index = buttons.index { |button| button['type'].to_s.upcase == CATALOG_BUTTON_TYPE }
    raise ArgumentError, 'Catalog template button is missing' if button_index.nil?

    [{
      type: 'button',
      sub_type: 'CATALOG',
      index: button_index,
      parameters: [{ type: 'action', action: { thumbnail_product_retailer_id: retailer_id } }]
    }]
  end

  def template_component(template, type)
    Array(template['components']).find { |component| component['type'].to_s.upcase == type }
  end

  def process_auto_flow_buttons(template, existing_button_components)
    buttons = Array(template_component(template, 'BUTTONS')&.[]('buttons'))
    covered_indices = existing_button_components.filter_map { |comp| comp[:index] || comp['index'] }
    buttons.filter_map.with_index do |button, index|
      next if button['type'].to_s.upcase != FLOW_BUTTON_TYPE || covered_indices.include?(index)

      {
        type: 'button', sub_type: 'flow', index: index,
        parameters: [{ type: 'action', action: { flow_token: build_template_flow_token(template, button) } }]
      }
    end
  end

  def ensure_signed_flow_button_tokens!(template, components)
    buttons = Array(template_component(template, 'BUTTONS')&.[]('buttons'))
    components.each { |comp| sign_flow_component_if_needed!(template, buttons, comp) }
  end

  def sign_flow_component_if_needed!(template, buttons, comp)
    return unless comp[:sub_type].to_s.casecmp('flow').zero?

    action = comp.dig(:parameters, 0, :action)
    return unless action.is_a?(Hash) && action[:flow_token].to_s.strip.in?(['', 'unused'])

    action[:flow_token] = build_template_flow_token(template, buttons[comp[:index].to_i] || {})
  end

  def build_template_flow_token(template, button)
    return 'unused' unless channel.is_a?(Channel::Whatsapp)

    cached_flow = find_cached_template_flow(button['flow_id']).to_h
    Whatsapp::Flows::TokenService.generate_flow_token(
      channel: channel,
      kind: cached_flow['kind'].presence || 'booking',
      conversation_id: message&.conversation_id,
      contact_id: message&.conversation&.contact_id,
      locale: cached_flow['locale'].presence || template['language']
    )
  end

  def find_cached_template_flow(flow_id)
    Array(channel.provider_config.to_h.dig('whatsapp_flows', 'flows')).find { |item| item['id'].to_s == flow_id.to_s }
  end
end
