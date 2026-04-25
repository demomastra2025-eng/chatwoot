# frozen_string_literal: true

class Confirmations::WhatsappDeliveryPayloadBuilder
  CONFIRMATION_TEMPLATE_NAME_PATTERN = /confirmation|confirm|подтверж/i

  def initialize(confirmation_request)
    @confirmation_request = confirmation_request
  end

  def message_params
    params = case delivery_strategy
             when 'native_buttons'
               native_button_params
             when 'channel_template'
               channel_template_params
             else
               manual_required_params
             end

    params.merge(delivery_strategy: delivery_strategy, delivery_policy: delivery_policy_payload)
  end

  private

  attr_reader :confirmation_request

  def delivery_strategy
    return @delivery_strategy if defined?(@delivery_strategy)

    @delivery_strategy = resolve_delivery_strategy
  end

  def resolve_delivery_strategy
    if free_text_policy.allowed?
      @selected_delivery_policy = free_text_policy
      return 'native_buttons'
    end

    if template_params.present? && template_policy.allowed?
      @selected_delivery_policy = template_policy
      return 'channel_template'
    end

    @selected_delivery_policy = template_params.present? ? template_policy : free_text_policy
    'manual_required'
  end

  def native_button_params
    {
      content: base_content,
      content_type: 'input_select',
      content_attributes: base_content_attributes.merge(items: native_items)
    }
  end

  def channel_template_params
    {
      content: base_content,
      content_type: 'text',
      content_attributes: base_content_attributes.merge(items: native_items, links: action_urls),
      template_params: template_params
    }
  end

  def manual_required_params
    {
      content: manual_required_content,
      content_type: 'text',
      private: true,
      content_attributes: base_content_attributes.merge(links: action_urls)
    }
  end

  def base_content
    [confirmation_request.title, confirmation_request.body].compact_blank.join("\n\n")
  end

  def manual_required_content
    [
      'Нужна ручная отправка подтверждения: не найден approved WhatsApp template для отправки вне 24-часового окна.',
      selected_delivery_policy&.reason,
      base_content,
      links_content
    ].compact_blank.join("\n")
  end

  def links_content
    [
      "Ссылки: подтвердить #{action_urls.fetch(:confirmed)},",
      "отменить #{action_urls.fetch(:declined)},",
      "перенести #{action_urls.fetch(:reschedule_requested)}."
    ].join(' ')
  end

  def base_content_attributes
    {
      confirmation_request_id: confirmation_request.id,
      confirmation_token: confirmation_request.token,
      confirmation_strategy: delivery_strategy
    }
  end

  def native_items
    [
      { title: 'Подтвердить', value: action_value('confirmed') },
      { title: 'Отменить', value: action_value('declined') },
      { title: 'Перенести', value: action_value('reschedule_requested') }
    ]
  end

  def action_value(decision)
    "confirmation:#{confirmation_request.token}:#{decision}"
  end

  def action_urls
    @action_urls ||= Confirmations::PayloadBuilder.action_urls(confirmation_request)
  end

  def delivery_policy_payload
    policy = selected_delivery_policy
    policy.as_json.merge(delivery_mode: policy.delivery_mode)
  end

  def selected_delivery_policy
    delivery_strategy
    @selected_delivery_policy
  end

  def free_text_policy
    @free_text_policy ||= delivery_policy('free_text')
  end

  def template_policy
    @template_policy ||= delivery_policy('channel_template', template_params: template_params)
  end

  def delivery_policy(content_kind, template_params: nil)
    Outbound::DeliveryPolicy.evaluate(
      conversation: confirmation_request.conversation,
      inbox: confirmation_request.inbox,
      content_kind: content_kind,
      template_params: template_params
    )
  end

  def template_params
    @template_params ||= build_template_params
  end

  def build_template_params
    explicit_params = explicit_template_params
    return explicit_params if explicit_params.present?

    template = approved_confirmation_template
    return {} if template.blank?

    {
      'name' => template[:name],
      'namespace' => template[:namespace],
      'language' => template[:language],
      'processed_params' => { 'body' => { '1' => confirmation_request.title, '2' => confirmation_request.body } }
    }.compact
  end

  def explicit_template_params
    metadata = confirmation_request.metadata.to_h.with_indifferent_access
    params = metadata[:whatsapp_template] || metadata[:channel_template] || metadata[:template_params]
    params.respond_to?(:to_h) ? params.to_h.with_indifferent_access : {}
  end

  def approved_confirmation_template
    quick_reply_templates.find { |template| template[:name].to_s.match?(CONFIRMATION_TEMPLATE_NAME_PATTERN) }
  end

  def quick_reply_templates
    @quick_reply_templates ||= template_catalog.as_json(status: 'approved')[:templates].select do |template|
      Array(template[:buttons]).any? { |button| button.with_indifferent_access[:type].to_s.casecmp('QUICK_REPLY').zero? }
    end
  end

  def template_catalog
    @template_catalog ||= Outbound::ChannelTemplateCatalog.new(inbox: confirmation_request.inbox)
  end
end
