class Captain::Tools::Copilot::SendMessageToConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'send_message_to_conversation'
  end

  description 'Send a public reply, private note, attachments, or an approved channel template to a conversation or ' \
              'selected communication-thread channel'
  param :conversation_id,
        type: :integer,
        desc: 'Conversation display ID. Optional when communication_thread_id + channel_key selects a thread channel',
        required: false
  param :communication_thread_id,
        type: :integer,
        desc: 'Optional communication thread display ID for unified omnichannel sends',
        required: false
  param :channel_key,
        type: :string,
        desc: 'Optional selected communication-thread channel key, for example conversation:123 or inbox:456',
        required: false
  param :target_inbox_id,
        type: :integer,
        desc: 'Optional target inbox ID when sending through an unlinked communication-thread channel',
        required: false
  param :target_contact_inbox_id,
        type: :integer,
        desc: 'Optional target contact inbox ID for the selected communication-thread channel',
        required: false
  param :content, type: :string,
                  desc: 'Message content to send. Optional when attachment_ids, artifact_ids, or channel_template template_params are provided',
                  required: false
  param :content_kind, type: :string,
                       desc: 'Message content kind: free_text or channel_template. Defaults to channel_template when template_params are provided',
                       required: false
  param :template_params, type: :object,
                          desc: 'Approved channel template params for WhatsApp/Twilio WhatsApp, including name, language, namespace, ' \
                                'and processed_params',
                          required: false
  param :attachment_ids, type: :array, desc: 'Optional ActiveStorage signed blob IDs to send as native message attachments', required: false
  param :artifact_ids, type: :array, desc: 'Optional opaque artifact IDs selected from custom HTTP tool artifact_candidates', required: false
  param :private_note, type: :boolean, desc: 'When true, send as a private note instead of a customer-visible message', required: false
  param :in_reply_to_message_id, type: :integer, desc: 'Optional message ID to reply to', required: false

  def execute(conversation_id: nil, communication_thread_id: nil, channel_key: nil, target_inbox_id: nil, target_contact_inbox_id: nil,
              content: nil, content_kind: nil, template_params: nil, attachment_ids: [], artifact_ids: [], private_note: nil,
              in_reply_to_message_id: nil)
    message = conversation_operations.send_message_to_conversation(
      conversation_id: conversation_id,
      communication_thread_id: communication_thread_id,
      channel_key: channel_key,
      target_inbox_id: target_inbox_id,
      target_contact_inbox_id: target_contact_inbox_id,
      content: content,
      content_kind: content_kind,
      template_params: template_params,
      private_note: private_note,
      in_reply_to_message_id: in_reply_to_message_id,
      attachment_ids: attachment_ids,
      artifact_ids: artifact_ids
    )

    formatted_payload(send_message_payload(message))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  def conversation_operations
    Captain::Tools::Operations::ConversationOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end

  def send_message_payload(message)
    payload = {
      action: 'send_message_to_conversation',
      conversation_id: message.conversation.display_id,
      message: message_payload(message)
    }

    communication_thread_state = Captain::ContextFields.communication_thread_state_for(
      account: account,
      conversation: message.conversation,
      actor: @user
    )
    payload[:communication_thread] = communication_thread_state if communication_thread_state.present?
    payload
  end

  def message_payload(message)
    {
      id: message.id,
      conversation_id: message.conversation.display_id,
      content: message.content,
      private: message.private,
      status: message.status,
      message_type: message.message_type,
      sender_type: message.sender_type,
      sender_id: message.sender_id,
      sender_name: message.sender&.try(:name),
      created_at: message.created_at&.iso8601,
      updated_at: message.updated_at&.iso8601,
      attachments: attachment_payloads(message),
      template_params: message.additional_attributes&.dig('template_params'),
      delivery_policy: message.additional_attributes&.dig('delivery_policy')
    }.compact
  end

  def attachment_payloads(message)
    message.attachments.map do |attachment|
      {
        id: attachment.id,
        file_type: attachment.file_type,
        filename: attachment.file.attached? ? attachment.file.filename.to_s : nil,
        content_type: attachment.file.attached? ? attachment.file.content_type : nil,
        byte_size: attachment.file.attached? ? attachment.file.byte_size : nil
      }.compact
    end
  end
end
