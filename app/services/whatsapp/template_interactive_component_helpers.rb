module Whatsapp::TemplateInteractiveComponentHelpers
  include Whatsapp::TemplateCarouselComponentHelpers

  AUTHENTICATION_CATEGORY = 'AUTHENTICATION'.freeze
  CAROUSEL_COMPONENT_TYPE = 'CAROUSEL'.freeze
  CATALOG_BUTTON_TYPE = 'CATALOG'.freeze

  private

  def process_interactive_components(template, processed_params)
    return process_authentication_button(processed_params) if authentication_template?(template)
    return process_carousel_component(template, processed_params) if carousel_template?(template)
    return process_catalog_button(template, processed_params) if catalog_template?(template)

    process_button_components(processed_params)
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
      parameters: [{
        type: 'action',
        action: { thumbnail_product_retailer_id: retailer_id }
      }]
    }]
  end

  def template_component(template, type)
    Array(template['components']).find { |component| component['type'].to_s.upcase == type }
  end
end
