class Outbound::DeliveryPolicy
  VALID_CONTENT_KINDS = %w[free_text channel_template].freeze
  WHATSAPP_TEMPLATE_REQUIRED_REASON = 'Official WhatsApp Business API requires an approved channel_template ' \
                                      'when the 24-hour customer service window is closed'.freeze
  TEMPLATE_ATTACHMENTS_UNSUPPORTED_REASON = 'Native attachments cannot be combined with channel_template messages; ' \
                                            'use template header/media parameters instead'.freeze

  Result = Struct.new(
    :allowed,
    :delivery_mode,
    :content_kind,
    :requires_template,
    :reason,
    :channel_type,
    :provider,
    :reply_window_open,
    :reply_window_closes_at,
    :allowed_content_kinds,
    :template,
    keyword_init: true
  ) do
    def allowed?
      allowed
    end

    def as_json(*_args)
      {
        allowed: allowed,
        delivery_mode: delivery_mode,
        content_kind: content_kind,
        requires_template: requires_template,
        reason: reason,
        channel_type: channel_type,
        provider: provider,
        reply_window_open: reply_window_open,
        reply_window_closes_at: reply_window_closes_at&.iso8601,
        allowed_content_kinds: allowed_content_kinds,
        template: template
      }.compact
    end
  end

  def self.evaluate(**)
    new(**).evaluate
  end

  def self.ensure!(**)
    result = evaluate(**)
    raise ArgumentError, result.reason unless result.allowed?

    result
  end

  def initialize(conversation: nil, inbox: nil, content_kind: nil, template_params: nil, attachments: [], scheduled_at: nil, private_note: false)
    @conversation = conversation
    @inbox = inbox || conversation&.inbox
    @content_kind = normalize_content_kind(content_kind, template_params)
    @template_params = normalize_template_params(template_params)
    @attachments = Array(attachments).compact_blank
    @scheduled_at = normalize_time(scheduled_at)
    @private_note = ActiveModel::Type::Boolean.new.cast(private_note)
  end

  def evaluate
    return allowed_result(delivery_mode: 'private_note') if private_note?
    return denied_result('Target inbox is required') if inbox.blank?
    return denied_result("Unsupported content_kind: #{content_kind}") unless VALID_CONTENT_KINDS.include?(content_kind)

    channel_template? ? evaluate_channel_template : evaluate_free_text
  end

  private

  attr_reader :conversation, :inbox, :content_kind, :template_params, :attachments, :scheduled_at

  def evaluate_free_text
    return allowed_result(delivery_mode: 'free_text') unless official_whatsapp_channel?
    return allowed_result(delivery_mode: 'free_text', reply_window_open: true) if reply_window_open_at_delivery?

    denied_result(
      WHATSAPP_TEMPLATE_REQUIRED_REASON,
      requires_template: true,
      allowed_content_kinds: ['channel_template']
    )
  end

  def evaluate_channel_template
    return denied_result('Channel templates are not supported for this channel') unless channel_template_supported?
    return denied_result('template_params are required for channel_template delivery', requires_template: true) if template_params.blank?
    return denied_result(TEMPLATE_ATTACHMENTS_UNSUPPORTED_REASON, requires_template: true) if attachments.present?

    template = template_catalog.find_template(template_params)
    return denied_result('Approved channel template was not found for the selected inbox/name/language', requires_template: true) if template.blank?

    allowed_result(delivery_mode: 'channel_template', requires_template: true, template: template)
  end

  def allowed_result(delivery_mode:, requires_template: false, reply_window_open: nil, template: nil)
    Result.new(
      allowed: true,
      delivery_mode: delivery_mode,
      content_kind: content_kind,
      requires_template: requires_template,
      channel_type: inbox&.channel_type,
      provider: provider_name,
      reply_window_open: reply_window_value(reply_window_open),
      reply_window_closes_at: reply_window_closes_at,
      allowed_content_kinds: allowed_content_kinds,
      template: template
    )
  end

  def denied_result(reason, requires_template: false, allowed_content_kinds: self.allowed_content_kinds)
    Result.new(
      allowed: false,
      delivery_mode: nil,
      content_kind: content_kind,
      requires_template: requires_template,
      reason: reason,
      channel_type: inbox&.channel_type,
      provider: provider_name,
      reply_window_open: reply_window_value,
      reply_window_closes_at: reply_window_closes_at,
      allowed_content_kinds: allowed_content_kinds
    )
  end

  def allowed_content_kinds
    return %w[free_text channel_template] if channel_template_supported? && reply_window_open_at_delivery?
    return ['channel_template'] if channel_template_supported? && !reply_window_open_at_delivery?

    ['free_text']
  end

  def channel_template?
    content_kind == 'channel_template'
  end

  def reply_window_value(value = nil)
    return nil unless official_whatsapp_channel?
    return value unless value.nil?

    reply_window_open_at_delivery?
  end

  def official_whatsapp_channel?
    channel.is_a?(Channel::Whatsapp)
  end

  def channel_template_supported?
    template_catalog.supports_channel_templates?
  end

  def twilio_whatsapp?
    channel.is_a?(Channel::TwilioSms) && channel.medium == 'whatsapp'
  end

  def reply_window_open_at_delivery?
    return true unless official_whatsapp_channel?
    return false if conversation.blank?
    return false if reply_window_closes_at.blank?

    delivery_time < reply_window_closes_at
  end

  def reply_window_closes_at
    return unless official_whatsapp_channel?

    last_incoming_message&.created_at&.+(Conversations::MessageWindowService::MESSAGING_WINDOW_24_HOURS)
  end

  def last_incoming_message
    @last_incoming_message ||= conversation&.messages&.where(account_id: conversation.account_id)&.incoming&.reorder(created_at: :desc)&.first
  end

  def delivery_time
    scheduled_at || Time.current
  end

  def template_catalog
    @template_catalog ||= Outbound::ChannelTemplateCatalog.new(inbox: inbox)
  end

  def provider_name
    return channel.provider if channel.is_a?(Channel::Whatsapp)
    return 'twilio_whatsapp' if twilio_whatsapp?

    channel&.class&.name
  end

  def channel
    inbox&.channel
  end

  def private_note?
    @private_note
  end

  def normalize_content_kind(value, template_params)
    normalized = value.to_s.strip
    return normalized if normalized.present?
    return 'channel_template' if channel_template_supported? && normalize_template_params(template_params).present?

    'free_text'
  end

  def normalize_template_params(value)
    return {} if value.blank?

    if value.is_a?(String)
      parsed_value = JSON.parse(value)
      return parsed_value.with_indifferent_access if parsed_value.is_a?(Hash)

      return {}
    end
    return value.to_unsafe_h.with_indifferent_access if value.respond_to?(:to_unsafe_h)
    return value.to_h.with_indifferent_access if value.respond_to?(:to_h)

    {}
  rescue JSON::ParserError
    {}
  end

  def normalize_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    return if value.blank?

    Time.zone.parse(value.to_s)
  end
end
