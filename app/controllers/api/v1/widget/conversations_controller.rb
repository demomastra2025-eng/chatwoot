class Api::V1::Widget::ConversationsController < Api::V1::Widget::BaseController
  include Events::Types
  before_action :render_not_found_if_empty, only: [:toggle_typing, :toggle_status, :set_custom_attributes, :destroy_custom_attributes]

  def index
    @conversation = conversation
  end

  def create
    with_locked_contact_identity do |locked_contact_ids|
      process_update_contact(locked_thread_contact_ids: locked_contact_ids)
      raise Conversations::IdentityResolver::ContactChanged if @contact_inbox.reload.contact_id != @contact.id

      @conversation = create_conversation
      conversation.messages.create!(message_params)
      # TODO: Temporary fix for message type cast issue, since message_type is returning as string instead of integer
      conversation.reload
    end
  end

  def process_update_contact(locked_thread_contact_ids: nil)
    @contact = contact_identify_action.perform(locked_thread_contact_ids: locked_thread_contact_ids)
    Current.contact = @contact
  end

  def contact_identify_action
    ContactIdentifyAction.new(
      contact: @contact,
      params: { email: contact_email, phone_number: contact_phone_number, name: contact_name },
      retain_original_contact_name: true,
      discard_invalid_attrs: true
    )
  end

  def update_last_seen
    head :ok && return if conversation.nil?

    conversation.contact_last_seen_at = DateTime.now.utc
    conversation.save!
    ::Conversations::UpdateMessageStatusJob.perform_later(conversation.id, conversation.contact_last_seen_at)
    head :ok
  end

  def transcript
    return head :too_many_requests if conversation.blank?
    return head :payment_required unless conversation.account.email_transcript_enabled?
    return head :too_many_requests unless conversation.account.within_email_rate_limit?

    send_transcript_email
    head :ok
  end

  def toggle_typing
    case permitted_params[:typing_status]
    when 'on'
      trigger_typing_event(CONVERSATION_TYPING_ON)
    when 'off'
      trigger_typing_event(CONVERSATION_TYPING_OFF)
    end

    head :ok
  end

  def toggle_status
    return head :forbidden unless @web_widget.end_conversation?

    unless conversation.resolved?
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'resolved' },
        actor: conversation.contact,
        source: 'contact'
      ).perform
    end
    head :ok
  end

  def set_custom_attributes
    conversation.update!(custom_attributes: merged_custom_attributes)
    render json: conversation
  end

  def destroy_custom_attributes
    conversation.custom_attributes = CustomAttributes::MutationService.destroy(
      conversation.custom_attributes,
      custom_attribute_keys_to_destroy
    )
    conversation.save!
    render json: conversation
  end

  private

  def with_locked_contact_identity
    loop do
      return ActiveRecord::Base.transaction(requires_new: true) do
        # ContactIdentifyAction can change phone or merge contacts. Merge
        # takes phone -> ordered thread advisors -> Contact, so reserve the
        # same order before the widget's outer transaction updates Contact.
        Contacts::PhoneIdentityLock.acquire!(account_id: @current_account.id)
        contact_id = @contact_inbox.reload.contact_id
        @contact = @current_account.contacts.find(contact_id)
        locked_ids = contact_identify_action.thread_lock_contact_ids
        locked_ids.each do |id|
          Conversations::CommunicationThreadResolver.lock_contact_thread!(@current_account.id, id)
        end
        raise Conversations::IdentityResolver::ContactChanged if @contact_inbox.reload.contact_id != contact_id

        @contact.reload
        yield locked_ids
      end
    rescue Conversations::IdentityResolver::ContactChanged, ContactIdentifyAction::ThreadContactChanged
      # A concurrent identity change must restart before any Contact lock is
      # retained. The transaction rolls back both the advisors and edits.
      @contact_inbox.reload
    end
  end

  def send_transcript_email
    return if conversation.contact&.email.blank?

    ConversationReplyMailer.with(account: conversation.account).conversation_transcript(
      conversation,
      conversation.contact.email
    )&.deliver_later
    conversation.account.increment_email_sent_count
  end

  def trigger_typing_event(event)
    Rails.configuration.dispatcher.dispatch(event, Time.zone.now, conversation: conversation, user: @contact)
  end

  def render_not_found_if_empty
    return head :not_found if conversation.nil?
  end

  def permitted_params
    params.permit(:id, :typing_status, :website_token, :email, contact: [:name, :email, :phone_number],
                                                               message: [:content, :referer_url, :timestamp, :echo_id],
                                                               custom_attributes: {})
  end

  def merged_custom_attributes
    return {} if explicit_empty_custom_attributes?

    CustomAttributes::MutationService.merge(conversation.custom_attributes, permitted_params[:custom_attributes])
  end

  def custom_attribute_keys_to_destroy
    permitted = params.permit(custom_attributes: [], custom_attribute: [])
    permitted[:custom_attributes] || permitted[:custom_attribute] || []
  end

  def explicit_empty_custom_attributes?
    raw_attributes = permitted_params[:custom_attributes]
    params.key?(:custom_attributes) &&
      (raw_attributes.is_a?(ActionController::Parameters) || raw_attributes.is_a?(Hash)) &&
      raw_attributes.empty?
  end
end
