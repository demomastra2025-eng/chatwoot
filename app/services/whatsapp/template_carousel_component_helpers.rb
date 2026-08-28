module Whatsapp::TemplateCarouselComponentHelpers
  CAROUSEL_HEADER_TYPES = %w[image video].freeze

  private

  def process_carousel_component(template, processed_params)
    template_cards = Array(template_component(template, 'CAROUSEL')&.[]('cards'))
    submitted_cards = Array(processed_params.dig('carousel', 'cards'))
    raise ArgumentError, 'Carousel template card parameters are required' if submitted_cards.length != template_cards.length

    cards = template_cards.each_with_index.map do |template_card, card_index|
      submitted_card = submitted_cards.find { |card| card['card_index'].to_i == card_index }
      raise ArgumentError, "Carousel card #{card_index + 1} parameters are required" if submitted_card.blank?

      {
        card_index: card_index,
        components: build_carousel_card_components(template, template_card, submitted_card, card_index)
      }
    end

    [{ type: 'carousel', cards: cards }]
  end

  def build_carousel_card_components(template, template_card, submitted_card, card_index)
    components = [build_carousel_header(template, template_card, submitted_card, card_index)]
    body_component = build_carousel_body(template_card, submitted_card, card_index)
    components << body_component if body_component
    components.concat(build_carousel_buttons(template_card, submitted_card, card_index))
  end

  def build_carousel_header(template, template_card, submitted_card, card_index)
    header = template_component(template_card, 'HEADER')
    media_type = header&.[]('format').to_s.downcase
    raise ArgumentError, "Carousel card #{card_index + 1} header must be image or video" unless CAROUSEL_HEADER_TYPES.include?(media_type)

    media_id = resolve_carousel_media_id(template, submitted_card, card_index, media_type)

    media_parameter = { type: media_type }
    media_parameter[media_type.to_sym] = { id: media_id }
    { type: 'header', parameters: [media_parameter] }
  end

  def resolve_carousel_media_id(template, submitted_card, card_index, media_type)
    submitted_header = submitted_card['header'].to_h
    media_id = submitted_header['media_id'].to_s.strip
    return media_id if media_id.present?

    raise ArgumentError, "Carousel card #{card_index + 1} Meta media ID is required" unless carousel_media_upload_supported?

    carousel_media_upload_service.call(
      media_type: media_type,
      source: carousel_template_media_source(template, card_index),
      temporary_blob_signed_id: submitted_header['media_blob_id'].to_s.strip.presence
    )
  end

  def build_carousel_body(template_card, submitted_card, card_index)
    body = template_component(template_card, 'BODY')
    return if body.blank? || body['text'].to_s.scan(/{{[^}]+}}/).empty?

    body_values = submitted_card['body'].to_h
    parameters = body['text'].to_s.scan(/{{([^}]+)}}/).flatten.map do |variable|
      value = body_values[variable].to_s
      raise ArgumentError, "Carousel card #{card_index + 1} body variable #{variable} is required" if value.blank?

      parameter_builder.build_parameter(value)
    end
    { type: 'body', parameters: parameters }
  end

  def build_carousel_buttons(template_card, submitted_card, card_index)
    template_buttons = Array(template_component(template_card, 'BUTTONS')&.[]('buttons'))
    submitted_buttons = Array(submitted_card['buttons']).index_by { |button| button['index'].to_i }

    template_buttons.filter_map.with_index do |button, button_index|
      build_carousel_button(button, submitted_buttons[button_index], card_index, button_index)
    end
  end

  def build_carousel_button(button, submitted_button, card_index, button_index)
    type = button['type'].to_s.upcase
    parameter = submitted_button&.[]('parameter').to_s.strip

    if type == 'QUICK_REPLY'
      return if parameter.blank?

      return carousel_button_payload('quick_reply', button_index, :payload, parameter)
    end
    return unless type == 'URL' && button['url'].to_s.include?('{{')

    raise ArgumentError, "Carousel card #{card_index + 1} URL button #{button_index + 1} parameter is required" if parameter.blank?

    carousel_button_payload('url', button_index, :text, parameter)
  end

  def carousel_button_payload(sub_type, index, parameter_type, value)
    parameter = { type: parameter_type.to_s }
    parameter[parameter_type] = value
    { type: 'button', sub_type: sub_type, index: index, parameters: [parameter] }
  end
end
