# The dialog of a person, opened by the person (the contact card, a calendar appointment, a deal) and not by a conversation.
#
# GET never writes anything: a person who has a dialog is answered with its id, a person who has none with a draft (the
# person and the channels the first message can go to). Nothing is stored for a draft, so opening the screen and leaving it,
# or importing thousands of patients, creates no conversation. The dialog is made by the first message, call or note
# (POST messages), through the same service as every later message, see CommunicationThreads::MessageCreateService.
class Api::V1::Accounts::Contacts::DialogsController < Api::V1::Accounts::Contacts::BaseController
  include CommunicationThreads::ControllerContext

  FEATURE_NAME = 'communication_threads'.freeze

  rescue_from CommunicationThreads::MessageCreateService::Error, with: :render_message_create_error
  rescue_from ArgumentError, with: :render_dialog_parameter_error

  before_action :ensure_communication_threads_feature_enabled!
  before_action :authorize_contact!

  def show
    thread = accessible_thread
    return render json: { communication_thread_id: thread.display_id } if thread

    @channels = CommunicationThreads::ChannelCapabilitiesBuilder.new(
      links: [],
      contact: @contact,
      available_inboxes: accessible_inboxes.to_a,
      include_unlinked: true
    ).perform
    @shared_phone_holder = Contacts::SharedPhone.holder_contact(@contact)
  end

  def create_message
    raise CommunicationThreads::MessageCreateService::Error.new('echo_id is required', code: 'echo_id_required') if params[:echo_id].blank?

    service = CommunicationThreads::MessageCreateService.new(
      contact: @contact,
      current_user: Current.user,
      params: permitted_message_params,
      accessible_inboxes: accessible_inboxes,
      accessible_conversations: accessible_conversations
    )
    @message = service.perform
    @communication_thread = service.communication_thread
    preload_accessible_links([@communication_thread], include_unlinked: true)
    preload_crm_deal_stages([@communication_thread])
    preload_meta_ad_referrals([@communication_thread])
    render 'api/v1/accounts/communication_threads/message'
  end

  private

  # The dialog the user can open: a thread that exists but whose conversations are all hidden from this user is no dialog
  # for him, and the first message joins that thread through the resolver as for any other channel.
  def accessible_thread
    thread = CommunicationThread.find_by(account_id: Current.account.id, contact_id: @contact.id)
    thread if thread.present? && accessible_links_for(thread).exists?
  end

  def authorize_contact!
    authorize @contact, :show?
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?(FEATURE_NAME)

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end

  def render_dialog_parameter_error(error)
    render_could_not_create_error(error.message)
  end
end
