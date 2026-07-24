module Whatsapp::IncomingRichMessageHelpers
  def rich_message_content(message)
    message.dig(:interactive, :nfm_reply, :body) ||
      message.dig(:order, :text) ||
      message.dig(:name, :formatted_name) ||
      structured_message_fallback(message)
  end

  def rich_message_content_attributes(message)
    attributes = {}
    add_nfm_content_attributes!(attributes, message.dig(:interactive, :nfm_reply))

    order = message[:order].to_h
    attributes[:whatsapp_order] = order.deep_stringify_keys if order.present?
    attributes
  end

  private

  def add_nfm_content_attributes!(attributes, raw_nfm_reply)
    nfm_reply = raw_nfm_reply.to_h.with_indifferent_access
    return if nfm_reply.blank?

    attributes[nfm_attribute_key(nfm_reply[:name])] = normalized_nfm_reply(nfm_reply)
  end

  def nfm_attribute_key(name)
    {
      'flow' => :whatsapp_flow_response,
      'address_message' => :whatsapp_address_response
    }.fetch(name, :whatsapp_nfm_response)
  end

  def normalized_nfm_reply(nfm_reply)
    {
      name: nfm_reply[:name],
      body: nfm_reply[:body],
      response: parse_nfm_response_json(nfm_reply[:response_json])
    }.compact.deep_stringify_keys
  end

  def parse_nfm_response_json(response_json)
    return if response_json.blank?
    return response_json if response_json.is_a?(Hash) || response_json.is_a?(Array)

    JSON.parse(response_json)
  rescue JSON::ParserError
    { '_raw' => response_json.to_s, '_invalid_json' => true }
  end

  def structured_message_fallback(message)
    return 'WhatsApp form response' if message.dig(:interactive, :nfm_reply).present?
    return 'WhatsApp order' if message[:order].present?
  end
end
