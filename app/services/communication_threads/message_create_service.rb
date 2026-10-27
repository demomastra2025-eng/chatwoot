# frozen_string_literal: true

# One message of a person, written from the dialog screen: into a channel the person already has a conversation in, or into a
# channel they have none in yet. The first message, call or note of a person who has no dialog yet starts the dialog.
#
# The send runs in one transaction under the lock of the person (CommunicationThreads::PersonLock), so
# - a refused send (a template is missing, the channel cannot be reached, the number belongs to someone else) leaves no
#   ContactInbox, conversation, thread or message behind;
# - two staff members who write to the same person at the same moment end up in one dialog;
# - the same echo_id (the key of one bubble of the screen) is answered with the message it created, never with a second one.
class CommunicationThreads::MessageCreateService
  # code: what the screen shows in plain words, see the ru texts PERSON_DIALOG.ERRORS (nil: an unexpected message).
  # details: what the words need (the name of the other contact when a chat identity is theirs).
  class Error < StandardError
    attr_reader :code, :details

    def initialize(message = nil, code: nil, details: nil)
      super(message)
      @code = code
      @details = details
    end
  end

  REPLAY_WINDOW = 24.hours

  attr_reader :message, :conversation, :communication_thread

  def initialize(contact:, current_user:, params:, accessible_inboxes:, accessible_conversations:)
    @contact = contact
    @current_user = current_user
    @params = params
    @accessible_inboxes = accessible_inboxes
    @accessible_conversations = accessible_conversations
  end

  def perform
    CommunicationThread.transaction do
      CommunicationThreads::PersonLock.lock!(account_id: contact.account_id, contact_id: contact.id)
      @message = message_for_echo_id
      @message ||= create_message!
    end

    @conversation = @message.conversation
    @communication_thread = person_thread || thread_made_for!(@conversation)
    @message
  end

  private

  attr_reader :contact, :current_user, :params, :accessible_inboxes, :accessible_conversations

  def create_message!
    # Read under the lock, so a thread another request has just made is never missed.
    @communication_thread = person_thread
    @conversation = selected_conversation || start_conversation!
    validate_send_capability!
    annotate_delivery_policy_params!
    Messages::MessageBuilder.new(current_user, @conversation, params).perform
  end

  def person_thread
    CommunicationThread.find_by(account_id: contact.account_id, contact_id: contact.id)
  end

  # The resolver builds the thread when a conversation is made; a conversation that existed before its thread did (the inbox keeps
  # one conversation per person) gets it here, by the same resolver.
  def thread_made_for!(conversation)
    conversation.refresh_communication_thread!
    CommunicationThread.find_by!(account_id: contact.account_id, contact_id: contact.id)
  end

  def message_for_echo_id
    key = params[:echo_id].to_s
    return if key.blank?

    Message.where(account_id: contact.account_id, message_type: Message.message_types[:outgoing])
           .where(conversation_id: accessible_conversations.where(contact_id: contact.id).select(:id))
           .where("messages.additional_attributes ->> 'echo_id' = ?", key)
           .where('messages.created_at > ?', REPLAY_WINDOW.ago)
           .reorder(:id).first
  end

  def selected_conversation
    return if selected_conversation_display_id.blank?

    Conversation.where(account_id: contact.account_id, id: accessible_links.select(:conversation_id))
                .find_by!(display_id: selected_conversation_display_id)
  end

  # A conversation in a channel the person has none in yet. Under the lock the thread is either there (the conversation joins it,
  # with its status, assignee and team) or not (the conversation starts the dialog: the resolver builds the thread and the link
  # when the transaction commits, before the caller renders anything).
  def start_conversation!
    raise Error.new('Contact is blocked', code: 'contact_blocked') if contact.blocked?

    contact_inbox = find_or_create_contact_inbox!(selected_inbox)
    conversation = ConversationBuilder.new(
      params: ActionController::Parameters.new(conversation_seed_params(contact_inbox)),
      contact_inbox: contact_inbox,
      started_by: current_user
    ).perform
    link_conversation!(conversation) if communication_thread.present?
    conversation
  end

  def selected_inbox
    inbox_id = selected_inbox_id || selected_contact_inbox&.inbox_id
    raise Error.new('Reply channel inbox_id is required', code: 'channel_unavailable') if inbox_id.blank?

    accessible_inboxes.find(inbox_id)
  end

  def selected_conversation_display_id
    conversation_id_from_channel_key || params[:conversation_id]
  end

  def selected_inbox_id
    inbox_id_from_channel_key || params[:target_inbox_id] || params[:inbox_id]
  end

  def conversation_id_from_channel_key
    params[:channel_key].to_s.delete_prefix('conversation:') if params[:channel_key].to_s.start_with?('conversation:')
  end

  def inbox_id_from_channel_key
    params[:channel_key].to_s.delete_prefix('inbox:') if params[:channel_key].to_s.start_with?('inbox:')
  end

  # The chat identity of the person in this inbox comes from the channels themselves (Contacts::ContactableInboxesService), never
  # from the client. A chat identity that already belongs to another contact is never taken over or renamed.
  def find_or_create_contact_inbox!(inbox)
    contact_inbox_from_params(inbox) || own_contact_inbox!(inbox)
  end

  def own_contact_inbox!(inbox)
    resolver = Outbound::ContactInboxResolver.new(inbox: inbox, contact: contact)
    source_id = resolver.resolved_source_id
    raise Error.new('Selected channel cannot be reached for this contact', code: 'channel_unavailable') if source_id.blank?

    contact_inbox = Reminders::PatientSubjectGuard.own_contact_inbox(inbox: inbox, contact: contact, source_id: source_id) { resolver.perform }
    return contact_inbox if contact_inbox.present?

    raise foreign_chat_identity_error(inbox, source_id)
  rescue ActionController::ParameterMissing => e
    raise Error.new(e.message, code: 'channel_unavailable')
  end

  def foreign_chat_identity_error(inbox, source_id)
    owner = ContactInbox.where(inbox_id: inbox.id, source_id: source_id.to_s).where.not(contact_id: contact.id).first&.contact
    Error.new('This chat identity already belongs to another contact', code: 'foreign_chat_identity',
                                                                       details: { contact_name: owner&.display_full_name })
  end

  def contact_inbox_from_params(inbox)
    contact_inbox = selected_contact_inbox
    return if contact_inbox.blank?

    return contact_inbox if contact_inbox.inbox_id == inbox.id

    raise Error.new('Reply channel contact_inbox does not belong to the selected inbox', code: 'channel_unavailable')
  end

  def selected_contact_inbox
    return @selected_contact_inbox if defined?(@selected_contact_inbox)

    contact_inbox_id = params[:target_contact_inbox_id] || params[:contact_inbox_id]
    @selected_contact_inbox = contact_inbox_id.blank? ? nil : contact.contact_inboxes.find(contact_inbox_id)
  end

  # The new conversation takes what the person's dialog already has. Without a dialog it is open and the builder decides the
  # assignee (the owner of the person when he works in this inbox, otherwise the sender).
  def conversation_seed_params(contact_inbox)
    {
      status: seed_status,
      assignee_id: communication_thread&.assignee_id,
      team_id: communication_thread&.team_id,
      priority: communication_thread&.priority,
      additional_attributes: {
        source: 'communication_thread',
        communication_thread_unified_inbox: true
      }.merge(communication_thread.present? ? { communication_thread_id: communication_thread.display_id } : {})
        .merge(telegram_chat_attributes(contact_inbox))
    }.compact
  end

  # A Telegram bot writes to the chat id of the conversation, which for a person the bot has never heard from is the Telegram id.
  def telegram_chat_attributes(contact_inbox)
    return {} unless contact_inbox.inbox.channel_type == 'Channel::Telegram'

    { chat_id: contact_inbox.source_id }
  end

  def seed_status
    return communication_thread.status if communication_thread.present? && CommunicationThread.statuses.key?(communication_thread.status)

    'open'
  end

  def link_conversation!(conversation)
    CommunicationThreadConversation.find_or_create_by!(account_id: communication_thread.account_id, conversation_id: conversation.id) do |link|
      link.communication_thread = communication_thread
      link.inbox_id = conversation.inbox_id
      link.contact_inbox_id = conversation.contact_inbox_id
      link.primary = false
    end
    communication_thread.association(:communication_thread_conversations).reset
    communication_thread.association(:conversations).reset
    conversation.association(:communication_thread).reset
    conversation.association(:communication_thread_conversation).reset
  end

  def validate_send_capability!
    capability = channel_capability_for(conversation)
    raise Error.new('Selected channel is not available for this communication thread', code: 'channel_unavailable') if capability.blank?

    validate_template_requirement!(capability)
    validate_text_delivery!(capability)
  end

  def validate_template_requirement!(capability)
    # A private note never reaches the customer, so the WhatsApp Cloud 24-hour template rule does not apply to it.
    return if private_message?
    return unless capability[:requires_template] && params[:template_params].blank?

    raise Error.new('Selected channel requires a template message', code: 'template_required')
  end

  def validate_text_delivery!(capability)
    return if private_message?

    raise Error.new('Selected channel cannot send messages: voice_call_only', code: 'channel_unavailable') if voice_channel?

    return if capability[:can_send_text] || capability[:requires_template]

    reason = capability[:disabled_reason].presence || 'not_replyable'
    raise Error.new("Selected channel cannot send messages: #{reason}", code: 'channel_unavailable')
  end

  def annotate_delivery_policy_params!
    delivery_policy = Outbound::DeliveryPolicy.evaluate(
      conversation: conversation,
      inbox: conversation.inbox,
      content_kind: normalized_content_kind,
      template_params: params[:template_params],
      attachments: Array(params[:attachments]).compact_blank,
      private_note: private_message?
    )
    unless delivery_policy.allowed?
      raise Error.new(delivery_policy.reason, code: delivery_policy.requires_template ? 'template_required' : 'channel_unavailable')
    end

    params[:delivery_policy] = delivery_policy.as_json unless private_message?
  end

  def normalized_content_kind
    normalized = params[:content_kind].to_s.strip
    return normalized if normalized.present?
    return 'channel_template' if channel_templates_supported? && params[:template_params].present?

    'free_text'
  end

  def channel_templates_supported?
    Outbound::ChannelTemplateCatalog.new(inbox: conversation.inbox).supports_channel_templates?
  end

  def private_message?
    ActiveModel::Type::Boolean.new.cast(params[:private])
  end

  def voice_channel?
    conversation.inbox.channel_type == 'Channel::Voice'
  end

  def channel_capability_for(conversation)
    capabilities.find do |capability|
      String(capability[:conversation_id]) == String(conversation.display_id) ||
        String(capability[:inbox_id]) == String(conversation.inbox_id)
    end
  end

  def capabilities
    @capabilities ||= CommunicationThreads::ChannelCapabilitiesBuilder.new(
      links: accessible_links.includes(:conversation, :contact_inbox, inbox: :channel),
      contact: contact,
      available_inboxes: accessible_inboxes,
      include_unlinked: true,
      deduplicate_linked: false
    ).perform
  end

  # The links of the person's dialog that this user may open (none while the person has no dialog).
  def accessible_links
    return CommunicationThreadConversation.none if communication_thread.blank?

    CommunicationThreadConversation.where(
      account_id: contact.account_id,
      communication_thread_id: communication_thread.id,
      conversation_id: accessible_conversations.select(:id)
    )
  end
end
