class Api::V1::Accounts::Contacts::CommunicationThreadsController < Api::V1::Accounts::Contacts::BaseController
  FEATURE_NAME = 'communication_threads'.freeze

  before_action :ensure_communication_threads_feature_enabled!

  def index
    conversations = Current.account.conversations.where(contact_id: @contact.id)
    conversations = Conversations::PermissionFilterService.new(
      conversations,
      Current.user,
      Current.account
    ).perform

    @communication_threads = CommunicationThread
                             .where(account_id: Current.account.id, contact_id: @contact.id)
                             .joins(:communication_thread_conversations)
                             .where(communication_thread_conversations: { conversation_id: conversations.select(:id) })
                             .distinct
                             .order(last_activity_at: :desc, id: :desc)
  end

  private

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?(FEATURE_NAME)

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end
end
