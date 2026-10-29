class Whatsapp::OutboundRichMessageBuilder # rubocop:disable Metrics/ClassLength
  SUPPORTED_TYPES = %w[location contacts reaction cta_url flow].freeze
  CTA_HEADER_TYPES = %w[text image video document].freeze
  FLOW_ACTIONS = %w[data_exchange navigate].freeze
  FLOW_MODES = %w[published draft].freeze
  FLOW_ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/
  CONTACT_LIMIT = 257
  CTA_BODY_LIMIT = 1024
  CTA_HEADER_LIMIT = 60
  CTA_FOOTER_LIMIT = 60
  CTA_BUTTON_LABEL_LIMIT = 20
  CONTACT_NAME_FIELDS = %i[formatted_name first_name last_name middle_name suffix prefix].freeze
  CONTACT_ORG_FIELDS = %i[company department title].freeze
  CONTACT_COLLECTION_FIELDS = {
    addresses: %i[street city state zip country country_code type],
    emails: %i[email type],
    phones: %i[phone type wa_id],
    urls: %i[url type]
  }.freeze

  def initialize(payload:, conversation: nil)
    @payload = payload.to_h.with_indifferent_access
    @conversation = conversation
  end

  def build
    raise ArgumentError, "Unsupported WhatsApp rich message type: #{type}" unless SUPPORTED_TYPES.include?(type)

    send("build_#{type}")
  end

  private

  attr_reader :payload, :conversation

  def type
    payload[:type].to_s
  end

  def build_location
    location = payload[:location].to_h.with_indifferent_access
    latitude = numeric_coordinate(location[:latitude], 'latitude', -90..90)
    longitude = numeric_coordinate(location[:longitude], 'longitude', -180..180)

    {
      type: 'location',
      content: {
        latitude: latitude,
        longitude: longitude,
        name: location[:name].presence,
        address: location[:address].presence
      }.compact
    }
  end

  def build_contacts
    contacts = Array(payload[:contacts])
    raise ArgumentError, 'WhatsApp contacts must include between 1 and 257 contacts' unless contacts.size.between?(1, CONTACT_LIMIT)

    {
      type: 'contacts',
      content: contacts.map { |contact| normalize_contact(contact) }
    }
  end

  def normalize_contact(contact)
    contact = contact.to_h.with_indifferent_access
    name = normalize_contact_fields(contact[:name], CONTACT_NAME_FIELDS)
    raise ArgumentError, 'WhatsApp contact formatted_name is required' if name[:formatted_name].blank?

    {
      birthday: contact[:birthday].presence,
      name: name.compact_blank,
      org: normalize_contact_fields(contact[:org], CONTACT_ORG_FIELDS).presence
    }.merge(normalize_contact_collections(contact)).compact
  end

  def normalize_contact_collections(contact)
    CONTACT_COLLECTION_FIELDS.to_h do |field, allowed_keys|
      [field, normalize_contact_collection(contact[field], allowed_keys)]
    end
  end

  def normalize_contact_collection(collection, allowed_keys)
    normalized = Array(collection).filter_map do |entry|
      normalize_contact_fields(entry, allowed_keys).presence
    end
    normalized.presence
  end

  def normalize_contact_fields(value, allowed_keys)
    value.to_h.with_indifferent_access.slice(*allowed_keys).to_h.symbolize_keys.compact_blank
  end

  def build_reaction
    reaction = payload[:reaction].to_h.with_indifferent_access
    message_id = reaction[:message_id].to_s
    emoji = reaction.key?(:emoji) ? reaction[:emoji].to_s : nil

    raise ArgumentError, 'WhatsApp reaction message_id is required' if message_id.blank?
    raise ArgumentError, 'WhatsApp reaction emoji must be present or an empty string to remove a reaction' if emoji.nil?
    raise ArgumentError, 'WhatsApp reaction emoji must contain a single emoji' if emoji.present? && !valid_reaction_emoji?(emoji)

    validate_reaction_target!(message_id)
    { type: 'reaction', content: { message_id: message_id, emoji: emoji } }
  end

  def valid_reaction_emoji?(emoji)
    return false unless emoji.scan(/\X/).one?

    emoji.match?(/\p{Emoji_Presentation}|\p{Extended_Pictographic}/) ||
      emoji.match?(/\A[#*0-9]\uFE0F?\u20E3\z/)
  end

  def validate_reaction_target!(message_id)
    return if conversation.blank?
    return if conversation.messages.exists?(source_id: message_id)

    raise ArgumentError, 'WhatsApp reaction target must belong to the same conversation'
  end

  def build_cta_url
    cta = payload[:cta_url].to_h.with_indifferent_access
    body = required_limited_text(cta[:body], 'CTA body', CTA_BODY_LIMIT)
    display_text = required_limited_text(cta[:display_text], 'CTA button label', CTA_BUTTON_LABEL_LIMIT)
    url = validate_http_url!(cta[:url], 'CTA URL')

    {
      type: 'interactive',
      content: {
        type: 'cta_url',
        header: build_cta_header(cta[:header]),
        body: { text: body },
        action: { name: 'cta_url', parameters: { display_text: display_text, url: url } },
        footer: build_cta_footer(cta[:footer])
      }.compact
    }
  end

  def build_cta_header(raw_header)
    header = raw_header.to_h.with_indifferent_access
    return if header.blank?

    header_type = header[:type].to_s
    raise ArgumentError, "Unsupported WhatsApp CTA header type: #{header_type}" unless CTA_HEADER_TYPES.include?(header_type)

    return { type: 'text', text: required_limited_text(header[:text], 'CTA header', CTA_HEADER_LIMIT) } if header_type == 'text'

    { type: header_type }.merge(header_type.to_sym => { link: validate_http_url!(header[:link], 'CTA header asset URL') })
  end

  def build_cta_footer(raw_footer)
    footer = raw_footer.to_s
    return if footer.blank?

    { text: required_limited_text(footer, 'CTA footer', CTA_FOOTER_LIMIT) }
  end

  def build_flow
    flow = payload[:flow].to_h.with_indifferent_access
    body = required_limited_text(flow[:body], 'Flow body', CTA_BODY_LIMIT)

    {
      type: 'interactive',
      content: {
        type: 'flow',
        header: build_cta_header(flow[:header]),
        body: { text: body },
        action: { name: 'flow', parameters: build_flow_parameters(flow) },
        footer: build_cta_footer(flow[:footer])
      }.compact
    }
  end

  def build_flow_parameters(flow)
    flow_action = validate_flow_option!(flow[:flow_action], 'data_exchange', FLOW_ACTIONS, 'flow_action')
    mode = validate_flow_option!(flow[:mode], 'published', FLOW_MODES, 'mode')
    parameters = {
      flow_message_version: '3',
      flow_token: flow[:flow_token].to_s.strip.presence || 'unused',
      flow_id: validate_flow_id!(flow[:flow_id]),
      flow_cta: validate_flow_cta!(flow[:flow_cta]),
      flow_action: flow_action
    }
    parameters[:mode] = 'draft' if mode == 'draft'
    parameters[:flow_action_payload] = build_flow_action_payload(flow[:flow_action_payload]) if flow_action == 'navigate'
    parameters
  end

  def validate_flow_cta!(raw_cta)
    cta = required_limited_text(raw_cta, 'Flow button label', CTA_BUTTON_LABEL_LIMIT)
    raise ArgumentError, 'WhatsApp Flow button label cannot contain emoji' if cta.match?(/\p{Emoji_Presentation}|\p{Extended_Pictographic}/)

    cta
  end

  def validate_flow_id!(raw_id)
    flow_id = raw_id.to_s.strip
    raise ArgumentError, 'WhatsApp Flow ID is required' if flow_id.blank?
    raise ArgumentError, 'WhatsApp Flow ID is invalid' unless flow_id.match?(FLOW_ID_FORMAT)

    flow_id
  end

  def validate_flow_option!(raw_value, default_value, allowed, label)
    value = raw_value.to_s.strip.presence || default_value
    raise ArgumentError, "Unsupported WhatsApp Flow #{label}: #{value}" unless allowed.include?(value)

    value
  end

  def build_flow_action_payload(raw_action_payload)
    action_payload = raw_action_payload.to_h.with_indifferent_access
    screen = action_payload[:screen].to_s.strip
    raise ArgumentError, 'WhatsApp Flow navigate screen is required' if screen.blank?

    result = { screen: screen }
    data = action_payload[:data]
    result[:data] = data if data.is_a?(Hash) && data.present?
    result
  end

  def numeric_coordinate(value, name, range)
    number = Float(value)
    raise ArgumentError, "WhatsApp location #{name} is out of range" unless range.cover?(number)

    number
  rescue TypeError, ArgumentError
    raise ArgumentError, "WhatsApp location #{name} must be a valid coordinate"
  end

  def required_limited_text(value, name, limit)
    text = value.to_s
    raise ArgumentError, "WhatsApp #{name} is required" if text.blank?
    raise ArgumentError, "WhatsApp #{name} can be up to #{limit} characters" if text.length > limit

    text
  end

  def validate_http_url!(value, name)
    uri = URI.parse(value.to_s)
    raise ArgumentError, "WhatsApp #{name} must be an HTTP or HTTPS URL" unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s
  rescue URI::InvalidURIError
    raise ArgumentError, "WhatsApp #{name} must be a valid URL"
  end
end
