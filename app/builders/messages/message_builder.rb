class Messages::MessageBuilder
  include ::FileTypeHelper
  include ::EmailHelper
  include ::DataHelper
  include ::Messages::MessageBuilderEmail

  BLANK_WHATSAPP_OUTBOUND_ERROR = 'WhatsApp message content, attachment, or template is required'.freeze

  attr_reader :message

  def initialize(user, conversation, params, skip_send_reply: false, skip_delivery_policy: false)
    @params = params
    @skip_send_reply = skip_send_reply
    @skip_delivery_policy = skip_delivery_policy
    @private = params[:private] || false
    @conversation = conversation
    @user = user
    @account = conversation.account
    @message_type = params[:message_type] || 'outgoing'
    @attachments = params[:attachments]
    @automation_rule = content_attributes&.dig(:automation_rule_id)
    return unless params.instance_of?(ActionController::Parameters)

    @in_reply_to = content_attributes&.dig(:in_reply_to)
    @items = content_attributes&.dig(:items)
  end

  def perform
    validate_whatsapp_outbound_content!
    validate_delivery_policy!
    @message = @conversation.messages.build(message_params)
    @message.preserve_waiting_since = preserve_waiting_since?
    @message.skip_send_reply = @skip_send_reply
    process_attachments
    process_emails
    # When the message has no quoted content, it will just be rendered as a regular message
    # The frontend is equipped to handle this case
    process_email_content
    @message.save!
    @message
  end

  private

  # Extracts content attributes from the given params.
  # - Converts ActionController::Parameters to a regular hash if needed.
  # - Attempts to parse a JSON string if content is a string.
  # - Returns an empty hash if content is not present, if there's a parsing error, or if it's an unexpected type.
  def content_attributes
    params = convert_to_hash(@params)
    content_attributes = params.fetch(:content_attributes, {})

    return safe_parse_json(content_attributes) if content_attributes.is_a?(String)
    return content_attributes if content_attributes.is_a?(Hash)

    {}
  end

  def process_attachments
    return if @attachments.blank?

    @attachments.each do |uploaded_attachment|
      attachment = @message.attachments.build(
        account_id: @message.account_id,
        file: uploaded_attachment
      )
      # Incoming messages (only allowed in Api inboxes) are never blocked by the storage limit.
      attachment.skip_storage_limit_validation! if message_type == 'incoming'

      attachment.file_type = if uploaded_attachment.is_a?(String)
                               file_type_by_signed_id(
                                 uploaded_attachment
                               )
                             else
                               file_type(uploaded_attachment&.content_type)
                             end
    end
  end

  def message_type
    if @conversation.inbox.channel_type != 'Channel::Api' && @message_type == 'incoming'
      raise StandardError, 'Incoming messages are only allowed in Api inboxes'
    end

    @message_type
  end

  def validate_delivery_policy!
    return unless message_type == 'outgoing'

    Outbound::PlaygroundDeliveryPolicy.ensure!(conversation: @conversation, private_note: @private)
    return if @skip_delivery_policy

    Outbound::DeliveryPolicy.ensure!(
      conversation: @conversation,
      inbox: @conversation.inbox,
      content_kind: @params[:content_kind],
      template_params: template_params,
      attachments: @attachments,
      private_note: @private
    )
  end

  def validate_whatsapp_outbound_content!
    return unless whatsapp_public_outgoing?

    validate_whatsapp_rich_payload! if whatsapp_rich_payload.present?
    return if deliverable_content_present?

    raise ArgumentError, BLANK_WHATSAPP_OUTBOUND_ERROR
  end

  def whatsapp_public_outgoing?
    message_type == 'outgoing' && !@private && @conversation.inbox&.channel.is_a?(Channel::Whatsapp)
  end

  def deliverable_content_present?
    @params[:content].present? || attachments_present? || template_params.present? || whatsapp_rich_payload.present?
  end

  def whatsapp_rich_payload
    content_attributes.to_h.with_indifferent_access[:whatsapp_payload]
  end

  def validate_whatsapp_rich_payload!
    Whatsapp::OutboundRichMessageBuilder.new(
      payload: whatsapp_rich_payload,
      conversation: @conversation
    ).build
  end

  def attachments_present?
    Array(@attachments).compact_blank.present?
  end

  def sender
    message_type == 'outgoing' ? (message_sender || @user) : @conversation.contact
  end

  def external_created_at
    @params[:external_created_at].present? ? { external_created_at: @params[:external_created_at] } : {}
  end

  def automation_rule_id
    @automation_rule.present? ? { content_attributes: { automation_rule_id: @automation_rule } } : {}
  end

  def campaign_id
    @params[:campaign_id]
  end

  def campaign_run_id
    @params[:campaign_run_id]
  end

  def template_params
    raw_template_params = @params[:template_params]
    return if raw_template_params.blank?
    return safe_parse_json(raw_template_params) if raw_template_params.is_a?(String)

    JSON.parse(raw_template_params.to_json)
  end

  def delivery_policy
    return if @params[:delivery_policy].blank?

    JSON.parse(@params[:delivery_policy].to_json)
  end

  def preserve_waiting_since?
    ActiveModel::Type::Boolean.new.cast(@params[:preserve_waiting_since])
  end

  def additional_attributes
    attrs = campaign_attributes
    attrs[:template_params] = template_params if template_params.present?
    attrs[:delivery_policy] = delivery_policy if delivery_policy.present?
    policy = Outbound::PlaygroundDeliveryPolicy.policy_for(conversation: @conversation)
    attrs[Outbound::PlaygroundDeliveryPolicy::ATTRIBUTE_KEY] = policy.deep_dup unless policy.nil?
    attrs.presence
  end

  def campaign_attributes
    attrs = {}
    attrs[:campaign_id] = campaign_id if campaign_id.present?
    attrs[:campaign_run_id] = campaign_run_id if campaign_run_id.present?
    attrs[:campaign_test_send] = true if ActiveModel::Type::Boolean.new.cast(@params[:campaign_test_send])
    attrs
  end

  def message_sender
    return if @params[:sender_type] != 'AgentBot'

    AgentBot.where(account_id: [nil, @conversation.account.id]).find_by(id: @params[:sender_id])
  end

  def additional_attributes_payload
    additional_attributes.present? ? { additional_attributes: additional_attributes } : {}
  end

  def message_params
    {
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      message_type: message_type,
      content: @params[:content],
      private: @private,
      sender: sender,
      content_type: @params[:content_type],
      content_attributes: content_attributes.presence,
      items: @items,
      in_reply_to: @in_reply_to,
      echo_id: @params[:echo_id],
      source_id: @params[:source_id]
    }.merge(external_created_at).merge(automation_rule_id).merge(additional_attributes_payload)
  end
end

Messages::MessageBuilder.prepend_mod_with('Messages::MessageBuilder')
