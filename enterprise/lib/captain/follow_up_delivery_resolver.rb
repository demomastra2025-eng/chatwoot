# frozen_string_literal: true

class Captain::FollowUpDeliveryResolver
  WINDOWED_FREE_TEXT_CHANNELS = %w[Channel::FacebookPage Channel::Instagram Channel::Tiktok].freeze

  Result = Struct.new(:allowed, :mode, :content, :template_params, :policy, :reason, :language, keyword_init: true) do
    def allowed?
      allowed
    end

    def template?
      mode == 'channel_template'
    end
  end

  pattr_initialize [:conversation!, :assistant!, :step!]

  def call
    return blocked_result('reply_window_closed') if bounded_free_text_window_closed?

    free_text_policy = Outbound::DeliveryPolicy.evaluate(conversation: conversation, content_kind: 'free_text')
    return allowed_result(mode: 'free_text', policy: free_text_policy) if free_text_policy.allowed?
    return blocked_result(free_text_policy.reason) unless free_text_policy.requires_template

    resolve_template
  end

  private

  def language
    @language ||= Captain::FollowUpLanguageResolver.new(conversation: conversation, assistant: assistant).call
  end

  def bounded_free_text_window_closed?
    WINDOWED_FREE_TEXT_CHANNELS.include?(conversation.inbox.channel_type) && !conversation.can_reply?
  end

  def resolve_template
    params = configured_template_params
    return blocked_result("template_language_missing:#{language}") if params.blank?

    policy = Outbound::DeliveryPolicy.evaluate(
      conversation: conversation,
      content_kind: 'channel_template',
      template_params: params
    )
    return blocked_result(policy.reason) unless policy.allowed?

    Campaigns::TemplateParamsValidator.validate!(inbox: conversation.inbox, template_params: params)
    content = policy.template.to_h[:body].to_s.strip
    return blocked_result('template_body_missing') if content.blank?

    allowed_result(mode: 'channel_template', content: content, template_params: params, policy: policy)
  rescue ArgumentError => e
    blocked_result(e.message)
  end

  def configured_template_params
    normalized_step = step.to_h.deep_stringify_keys
    inbox_variants = normalized_step.fetch('template_variants_by_inbox', {}).to_h
    variants = inbox_variants[conversation.inbox_id.to_s].to_h
    global_variants = normalized_step.fetch('template_variants', {}).to_h
    variant = variants[language].presence || variants[language.tr('-', '_')].presence ||
              global_variants[language].presence || global_variants[language.tr('-', '_')].presence
    variant.to_h.deep_stringify_keys.presence
  end

  def allowed_result(mode:, policy:, content: nil, template_params: nil)
    Result.new(
      allowed: true,
      mode: mode,
      content: content,
      template_params: template_params,
      policy: policy,
      language: language
    )
  end

  def blocked_result(reason)
    Result.new(allowed: false, reason: reason.to_s.presence || 'delivery_not_allowed', language: language)
  end
end
