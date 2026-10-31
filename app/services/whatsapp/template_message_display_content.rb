# frozen_string_literal: true

# Reconstruct legacy template text for presentation only. Never persist or send it.
class Whatsapp::TemplateMessageDisplayContent
  def initialize(message)
    @message = message
  end

  def render
    return unless eligible? && attributes['template_params'].is_a?(Hash)

    params = resolved_template_params
    return if params['name'].blank? || params['language'].blank?

    Whatsapp::TemplateMessageRenderer.new(
      channel: channel, template_params: params, templates: [template_snapshot], strict_language: true
    ).render_text
  end

  private

  attr_reader :message

  def eligible?
    return false unless empty_public_outgoing_text?

    channel.is_a?(Channel::Whatsapp) && message.account_id == message.inbox.account_id && channel.account_id == message.account_id
  end

  def empty_public_outgoing_text?
    message.content.blank? && message.outgoing? && message.text? && !message.private? && !ActiveModel::Type::Boolean.new.cast(message.deleted)
  end

  def channel
    @channel ||= message.inbox&.channel
  end

  def attributes
    @attributes ||= normalize_hash(message.additional_attributes)
  end

  def template_params
    normalize_hash(attributes['template_params'])
  end

  def template_snapshot
    @template_snapshot ||= normalize_hash(normalize_hash(attributes['delivery_policy'])['template'])
  end

  def resolved_template_params
    params = template_params.reverse_merge(template_snapshot.slice('name'))
    language = params['language'].presence || params['language_code'].presence || template_snapshot['language']
    params['language'] = Whatsapp::SupportedLanguages.normalize_code(language)
    params
  end

  def normalize_hash(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end
end
