class Api::V1::Accounts::ConversationsController < Api::V1::Accounts::BaseController
  include Events::Types
  include DateRangeHelper
  include HmacConcern

  rescue_from Conversations::StatusReasonConfig::Error, with: :render_status_reason_error

  before_action :conversation, except: [:index, :meta, :sidebar_unread_counts, :search, :create, :filter]
  before_action :inbox, :contact, :contact_inbox, only: [:create]
  around_action :with_list_presence_cache, only: [:index, :filter]

  ATTACHMENT_RESULTS_PER_PAGE = 100

  def index
    result = conversation_finder.perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
    preload_list_presence
    preload_crm_deal_stages(@conversations)
    preload_scheduling_appointment_statuses(@conversations)
    preload_directional_message_timestamps(@conversations)
  end

  def meta
    result = conversation_finder.perform_meta_only
    @conversations_count = result[:count]
  end

  def sidebar_unread_counts
    @sidebar_unread_counts = Conversations::SidebarUnreadCountService.new(
      account: Current.account,
      user: Current.user
    ).perform
  end

  def search
    result = conversation_finder.perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
  end

  def attachments
    @attachments_count = @conversation.attachments.count
    @attachments = @conversation.attachments
                                .includes(
                                  { file_attachment: :blob },
                                  message: [
                                    :inbox,
                                    :sender,
                                    { conversation: { contact_inbox: :channel_profile } }
                                  ]
                                )
                                .order(created_at: :desc)
                                .page(attachment_params[:page])
                                .per(ATTACHMENT_RESULTS_PER_PAGE)
  end

  def show
    preload_crm_deal_stages([@conversation])
    preload_scheduling_appointment_statuses([@conversation])
    preload_directional_message_timestamps([@conversation])
  end

  def create
    ActiveRecord::Base.transaction do
      @conversation = ConversationBuilder.new(params: params, contact_inbox: @contact_inbox).perform
      Messages::MessageBuilder.new(Current.user, @conversation, params[:message]).perform if params[:message].present?
    end
    preload_crm_deal_stages([@conversation])
    preload_scheduling_appointment_statuses([@conversation])
    preload_directional_message_timestamps([@conversation])
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end

  def update
    @conversation.update!(permitted_update_params)
    preload_crm_deal_stages([@conversation])
    preload_scheduling_appointment_statuses([@conversation])
    preload_directional_message_timestamps([@conversation])
  end

  def filter
    result = ::Conversations::FilterService.new(params.permit!, current_user, current_account).perform
    @conversations = result[:conversations]
    @conversations_count = result[:count]
    preload_list_presence
    preload_crm_deal_stages(@conversations)
    preload_scheduling_appointment_statuses(@conversations)
    preload_directional_message_timestamps(@conversations)
  rescue CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue => e
    render_could_not_create_error(e.message)
  end

  def mute
    @conversation.mute!
    head :ok
  end

  def unmute
    @conversation.unmute!
    head :ok
  end

  def transcript
    render json: { error: 'email param missing' }, status: :unprocessable_content and return if params[:email].blank?
    return render_payment_required('Email transcript is not available on your plan') unless @conversation.account.email_transcript_enabled?
    return head :too_many_requests unless @conversation.account.within_email_rate_limit?

    ConversationReplyMailer.with(account: @conversation.account).conversation_transcript(@conversation, params[:email])&.deliver_later
    @conversation.account.increment_email_sent_count
    head :ok
  end

  def toggle_status
    # FIXME: move this logic into a service object
    if pending_to_open_by_bot?
      @conversation.bot_handoff!
      @status = true
    else
      @status = transition_conversation_status!
    end
    assign_conversation if should_assign_conversation?
  end

  def pending_to_open_by_bot?
    return false unless Current.user.is_a?(AgentBot)

    @conversation.status == 'pending' && params[:status] == 'open'
  end

  def should_assign_conversation?
    @conversation.status == 'open' && Current.user.is_a?(User) && Current.user&.agent?
  end

  def toggle_priority
    @conversation.toggle_priority(params[:priority])
    head :ok
  end

  def toggle_typing_status
    typing_status_manager = ::Conversations::TypingStatusManager.new(@conversation, Current.user, params)
    typing_status_manager.toggle_typing_status
    head :ok
  end

  def update_last_seen
    Notification::MarkConversationReadService.new(user: Current.user, account: Current.account, conversation: @conversation).perform
    Conversations::MarkReadService.new(
      conversation: @conversation,
      user: Current.user
    ).perform
    @conversation.reload
    preload_crm_deal_stages([@conversation])
    preload_scheduling_appointment_statuses([@conversation])
    preload_directional_message_timestamps([@conversation])
    render :update_last_seen
  end

  def unread
    last_incoming_message = @conversation.messages.incoming.last
    return head :ok if last_incoming_message.blank?

    last_seen_at = last_incoming_message.created_at - 1.second
    Conversations::RecordUserReadStateService.new(conversation: @conversation, user: Current.user).perform(last_seen_at: last_seen_at)
    Conversations::LastSeenUpdater.new(conversation: @conversation).perform(
      last_seen_at: last_seen_at,
      update_assignee: true
    )
    head :ok
  end

  def custom_attributes
    @conversation.custom_attributes = merged_custom_attributes
    @conversation.save!
    render :custom_attributes
  end

  def destroy_custom_attributes
    @conversation.custom_attributes = CustomAttributes::MutationService.destroy(
      @conversation.custom_attributes,
      custom_attribute_keys_to_destroy
    )
    @conversation.save!
    render :custom_attributes
  end

  def destroy
    authorize @conversation, :destroy?
    ::DeleteObjectJob.perform_later(@conversation, Current.user, request.ip)
    head :ok
  end

  private

  def with_list_presence_cache(&)
    OnlineStatusTracker.with_presence_cache(&)
  end

  def preload_list_presence
    @conversation_list_preloader = Conversations::ListPreloader.new(
      account: Current.account,
      conversations: @conversations,
      user: Current.user
    ).perform
    ActiveRecord::Associations::Preloader.new(records: @conversations, associations: [:assignee, { contact: :owner }]).call
    contacts = @conversations.map(&:contact)
    users = @conversations.filter_map(&:assignee) + contacts.filter_map(&:owner)
    OnlineStatusTracker.preload_presence(Current.account.id, 'Contact', contacts.map(&:id))
    OnlineStatusTracker.preload_presence(Current.account.id, 'User', users.map(&:id))
  end

  def permitted_update_params
    # TODO: Move the other conversation attributes to this method and remove specific endpoints for each attribute
    params.permit(:priority)
  end

  def attachment_params
    params.permit(:page)
  end

  def set_conversation_status
    @conversation.status = params[:status]
    @conversation.snoozed_until = parse_date_time(params[:snoozed_until].to_s) if params[:snoozed_until]
  end

  def transition_conversation_status!
    Conversations::StatusTransitionService.new(
      conversation: @conversation,
      params: status_transition_params,
      actor: Current.user,
      source: 'api'
    ).perform
  end

  def status_transition_params
    params.permit(:status, :snoozed_until, :status_reason)
  end

  def render_status_reason_error(error)
    render json: { error: error.message, code: error.code, details: error.details }, status: error.status
  end

  def assign_conversation
    @conversation.assignee = current_user
    @conversation.save!
  end

  def conversation
    @conversation ||= Current.account.conversations.find_by!(display_id: params[:id])
    authorize @conversation, :show?
  end

  def inbox
    return if params[:inbox_id].blank?

    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :show?
  end

  def contact
    return if params[:contact_id].blank?

    @contact = Current.account.contacts.find(params[:contact_id])
  end

  def contact_inbox
    @contact_inbox = build_contact_inbox

    # fallback for the old case where we do look up only using source id
    # In future we need to change this and make sure we do look up on combination of inbox_id and source_id
    # and deprecate the support of passing only source_id as the param
    @contact_inbox ||= scoped_contact_inboxes.find_by!(source_id: params[:source_id])
    authorize @contact_inbox.inbox, :show?
  rescue ActiveRecord::RecordNotUnique
    render json: { error: 'source_id should be unique' }, status: :unprocessable_content
  end

  def build_contact_inbox
    return if @inbox.blank? || @contact.blank?
    return scoped_contact_inboxes.find(params[:contact_inbox_id]) if params[:contact_inbox_id].present?

    ContactInboxBuilder.new(
      contact: @contact,
      inbox: @inbox,
      source_id: params[:source_id],
      hmac_verified: hmac_verified?
    ).perform
  end

  def scoped_contact_inboxes
    scope = ::ContactInbox.joins(:inbox).where(inboxes: { account_id: Current.account.id })
    scope = scope.where(inbox_id: @inbox.id) if @inbox.present?
    scope = scope.where(contact_id: @contact.id) if @contact.present?
    scope
  end

  def conversation_finder
    @conversation_finder ||= ConversationFinder.new(Current.user, params)
  end

  def preload_crm_deal_stages(conversations)
    @crm_deal_stages_by_conversation_id =
      Crm::DealDialogStageContextBuilder.new(account: Current.account).for_conversations(conversations)
  end

  def preload_scheduling_appointment_statuses(conversations)
    @scheduling_appointment_statuses_by_conversation_id =
      Scheduling::AppointmentDialogStatusContextBuilder.new(account: Current.account).for_conversations(conversations)
  end

  def preload_directional_message_timestamps(conversations)
    @last_message_activity_by_conversation_id =
      Conversations::DirectionalMessageTimestampPreloader.new(account: Current.account).for_conversations(conversations)
  end

  def assignee?
    @conversation.assignee_id? && Current.user == @conversation.assignee
  end

  def merged_custom_attributes
    incoming_attributes = params.permit(custom_attributes: {})[:custom_attributes]
    return {} if explicit_empty_custom_attributes?(incoming_attributes)
    return @conversation.custom_attributes if incoming_attributes.blank?

    CustomAttributes::MutationService.merge(@conversation.custom_attributes, incoming_attributes)
  end

  def custom_attribute_keys_to_destroy
    params.permit(custom_attributes: [])[:custom_attributes] || []
  end

  def explicit_empty_custom_attributes?(incoming_attributes)
    params.key?(:custom_attributes) &&
      (incoming_attributes.is_a?(ActionController::Parameters) || incoming_attributes.is_a?(Hash)) &&
      incoming_attributes.empty?
  end
end

Api::V1::Accounts::ConversationsController.prepend_mod_with('Api::V1::Accounts::ConversationsController')
