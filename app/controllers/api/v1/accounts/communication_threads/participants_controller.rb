class Api::V1::Accounts::CommunicationThreads::ParticipantsController < Api::V1::Accounts::BaseController
  before_action :ensure_communication_threads_feature_enabled!
  before_action :set_communication_thread

  def show
    authorize @communication_thread, :show?
    load_participants
  end

  def create
    authorize @communication_thread, :manage_participants?
    CommunicationThreads::ParticipationService.new(
      communication_thread: @communication_thread,
      actor: Current.user
    ).add!(user_id: participant_user_id, idempotency_key: request.headers['Idempotency-Key'])
    load_participants
    render :show
  end

  def destroy
    authorize_participant_removal!
    CommunicationThreads::ParticipationService.new(
      communication_thread: @communication_thread,
      actor: Current.user
    ).remove!(user_id: participant_user_id, idempotency_key: request.headers['Idempotency-Key'])
    load_participants
    render :show
  end

  private

  def set_communication_thread
    @communication_thread = CommunicationThread.find_by!(
      account_id: Current.account.id,
      display_id: params[:communication_thread_id]
    )
  end

  def load_participants
    @participants = @communication_thread.communication_thread_participants.includes(user: { avatar_attachment: :blob }).order(:created_at, :id)
  end

  def participant_user_id
    raw_user_ids = params[:user_id].present? ? [params[:user_id]] : Array(params[:user_ids])
    raise ActionController::ParameterMissing, :user_id unless raw_user_ids.one?

    Integer(raw_user_ids.first)
  rescue ArgumentError, TypeError
    raise ActionController::ParameterMissing, :user_id
  end

  def authorize_participant_removal!
    if participant_user_id == Current.user.id
      authorize @communication_thread, :leave?
    else
      authorize @communication_thread, :manage_participants?
    end
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?('communication_threads')

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end
end
