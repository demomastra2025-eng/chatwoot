# frozen_string_literal: true

class CommunicationThreads::MessageCreateService
  class Error < StandardError; end

  attr_reader :message, :conversation

  def initialize(communication_thread:, current_user:, params:, accessible_inboxes:, accessible_links:)
    @communication_thread = communication_thread
    @current_user = current_user
    @params = params
    @accessible_inboxes = accessible_inboxes
    @accessible_links = accessible_links
  end

  def perform
    CommunicationThread.transaction do
      @conversation = selected_conversation || create_unlinked_conversation!
      validate_send_capability!
      annotate_delivery_policy_params!
      @message = Messages::MessageBuilder.new(@current_user, @conversation, @params).perform
      @communication_thread.reload
    end

    @message
  end

  private

  attr_reader :communication_thread, :current_user, :params, :accessible_inboxes, :accessible_links

  def selected_conversation
    return if selected_conversation_display_id.blank?

    accessible_conversations.find_by!(display_id: selected_conversation_display_id)
  end

  def create_unlinked_conversation!
    inbox = selected_inbox
    contact_inbox = find_or_create_contact_inbox!(inbox)
    conversation = ConversationBuilder.new(
      params: ActionController::Parameters.new(conversation_seed_params),
      contact_inbox: contact_inbox
    ).perform
    sync_conversation_defaults!(conversation)
    link_conversation!(conversation)
    communication_thread.association(:communication_thread_conversations).reset
    communication_thread.association(:conversations).reset
    conversation.association(:communication_thread).reset
    conversation.association(:communication_thread_conversation).reset
    conversation
  end

  def selected_inbox
    inbox_id = selected_inbox_id || selected_contact_inbox&.inbox_id
    raise Error, 'Reply channel inbox_id is required' if inbox_id.blank?

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

  def find_or_create_contact_inbox!(inbox)
    contact_inbox_from_params(inbox) ||
      communication_thread.contact.contact_inboxes.where(inbox_id: inbox.id).order(:id).first ||
      ContactInboxBuilder.new(contact: communication_thread.contact, inbox: inbox, source_id: params[:source_id]).perform
  rescue ActionController::ParameterMissing => e
    raise Error, e.message
  end

  def contact_inbox_from_params(inbox)
    contact_inbox = selected_contact_inbox
    return if contact_inbox.blank?

    return contact_inbox if contact_inbox.inbox_id == inbox.id

    raise Error, 'Reply channel contact_inbox does not belong to the selected inbox'
  end

  def selected_contact_inbox
    return @selected_contact_inbox if defined?(@selected_contact_inbox)

    contact_inbox_id = params[:target_contact_inbox_id] || params[:contact_inbox_id]
    @selected_contact_inbox = if contact_inbox_id.blank?
                                nil
                              else
                                communication_thread.contact.contact_inboxes.find(contact_inbox_id)
                              end
  end

  def conversation_seed_params
    {
      status: seed_status,
      assignee_id: communication_thread.assignee_id,
      team_id: communication_thread.team_id,
      additional_attributes: {
        source: 'communication_thread',
        communication_thread_id: communication_thread.display_id,
        communication_thread_unified_inbox: true
      }
    }
  end

  def seed_status
    return communication_thread.status if CommunicationThread.statuses.key?(communication_thread.status)

    'open'
  end

  def sync_conversation_defaults!(conversation)
    attrs = {}
    attrs[:priority] = communication_thread.priority if communication_thread.priority.present?
    attrs[:assignee_id] = communication_thread.assignee_id if communication_thread.assignee_id.present?
    attrs[:team_id] = communication_thread.team_id if communication_thread.team_id.present?
    conversation.update!(attrs) if attrs.present?
  end

  def link_conversation!(conversation)
    CommunicationThreadConversation.find_or_create_by!(account_id: communication_thread.account_id, conversation_id: conversation.id) do |link|
      link.communication_thread = communication_thread
      link.inbox_id = conversation.inbox_id
      link.contact_inbox_id = conversation.contact_inbox_id
      link.primary = false
    end
  end

  def validate_send_capability!
    capability = channel_capability_for(conversation)
    raise Error, 'Selected channel is not available for this communication thread' if capability.blank?

    validate_reauthorization!(capability)
    validate_template_requirement!(capability)
    validate_text_delivery!(capability)
  end

  def validate_reauthorization!(capability)
    return unless capability[:reauthorization_required]

    raise Error, 'Selected channel requires reauthorization'
  end

  def validate_template_requirement!(capability)
    return unless capability[:requires_template] && params[:template_params].blank?

    raise Error, 'Selected channel requires a template message'
  end

  def validate_text_delivery!(capability)
    return if private_message?

    raise Error, 'Selected channel cannot send messages: voice_call_only' if voice_channel?

    return if capability[:can_send_text] || capability[:requires_template]

    reason = capability[:disabled_reason].presence || 'not_replyable'
    raise Error, "Selected channel cannot send messages: #{reason}"
  end

  def annotate_delivery_policy_params!
    delivery_policy = Outbound::DeliveryPolicy.ensure!(
      conversation: conversation,
      inbox: conversation.inbox,
      content_kind: normalized_content_kind,
      template_params: params[:template_params],
      attachments: Array(params[:attachments]).compact_blank,
      private_note: private_message?
    )

    params[:delivery_policy] = delivery_policy.as_json unless private_message?
  rescue ArgumentError => e
    raise Error, e.message
  end

  def normalized_content_kind
    normalized = params[:content_kind].to_s.strip
    return normalized if normalized.present?

    'free_text'
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
      contact: communication_thread.contact,
      available_inboxes: accessible_inboxes,
      include_unlinked: true,
      deduplicate_linked: false
    ).perform
  end

  def accessible_conversations
    @accessible_conversations ||= Current.account.conversations.where(id: accessible_links.select(:conversation_id))
  end
end
