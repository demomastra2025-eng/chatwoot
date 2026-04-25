# frozen_string_literal: true

class Confirmations::DeliveryPayloadBuilder
  NATIVE_BUTTON_CHANNELS = %w[Channel::Telegram Channel::Line Channel::FacebookPage].freeze
  LINK_BUTTON_CHANNELS = %w[Channel::Email].freeze

  def initialize(confirmation_request)
    @confirmation_request = confirmation_request
  end

  def message_params
    return whatsapp_payload_builder.message_params if whatsapp_cloud_channel?

    params = case delivery_strategy
             when 'native_buttons'
               native_button_params
             when 'link_buttons'
               link_button_params
             else
               text_reply_params
             end

    params.merge(delivery_strategy: delivery_strategy, delivery_policy: delivery_policy_payload)
  end

  private

  attr_reader :confirmation_request

  def delivery_strategy
    @delivery_strategy ||= if NATIVE_BUTTON_CHANNELS.include?(channel_type)
                             'native_buttons'
                           elsif LINK_BUTTON_CHANNELS.include?(channel_type)
                             'link_buttons'
                           else
                             'text_reply'
                           end
  end

  def native_button_params
    {
      content: base_content,
      content_type: 'input_select',
      content_attributes: base_content_attributes.merge(items: native_items)
    }
  end

  def link_button_params
    {
      content: link_content,
      content_type: 'text',
      content_attributes: base_content_attributes.merge(links: action_urls)
    }
  end

  def text_reply_params
    {
      content: text_reply_content,
      content_type: 'text',
      content_attributes: base_content_attributes.merge(links: action_urls)
    }
  end

  def base_content
    [confirmation_request.title, confirmation_request.body].compact_blank.join("\n\n")
  end

  def link_content
    [
      base_content,
      "Подтвердить: #{action_urls.fetch(:confirmed)}",
      "Отменить: #{action_urls.fetch(:declined)}",
      "Перенести: #{action_urls.fetch(:reschedule_requested)}"
    ].join("\n")
  end

  def text_reply_content
    [
      base_content,
      'Ответьте "Да", "Нет" или "Перенести".',
      links_content
    ].join("\n")
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
    policy = Outbound::DeliveryPolicy.evaluate(
      conversation: confirmation_request.conversation,
      inbox: confirmation_request.inbox,
      content_kind: 'free_text'
    )
    policy.as_json.merge(delivery_mode: policy.delivery_mode)
  end

  def whatsapp_payload_builder
    Confirmations::WhatsappDeliveryPayloadBuilder.new(confirmation_request)
  end

  def whatsapp_cloud_channel?
    channel = confirmation_request.inbox&.channel

    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end

  def channel_type
    confirmation_request.inbox&.channel_type.to_s
  end
end
