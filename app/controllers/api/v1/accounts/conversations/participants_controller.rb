class Api::V1::Accounts::Conversations::ParticipantsController < Api::V1::Accounts::Conversations::BaseController
  before_action :reject_legacy_participation!, if: :communication_threads_enabled?

  def show
    @participants = @conversation.conversation_participants
  end

  def create
    ActiveRecord::Base.transaction do
      @participants = participants_to_be_added_ids.map { |user_id| find_or_create_participant(user_id) }
    end
  end

  def update
    ActiveRecord::Base.transaction do
      participants_to_be_added_ids.each { |user_id| find_or_create_participant(user_id) }
      participants_to_be_removed_ids.each { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    @participants = @conversation.conversation_participants
    render action: 'show'
  end

  def destroy
    ActiveRecord::Base.transaction do
      params[:user_ids].map { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    head :ok
  end

  private

  def conversation
    return if communication_threads_enabled?

    super
  end

  def communication_threads_enabled?
    Current.account&.feature_enabled?('communication_threads')
  end

  def reject_legacy_participation!
    render json: {
      error: 'Conversation participants have moved to the communication thread API'
    }, status: :gone
  end

  def participants_to_be_added_ids
    params[:user_ids] - current_participant_ids
  end

  def participants_to_be_removed_ids
    current_participant_ids - params[:user_ids]
  end

  def current_participant_ids
    @current_participant_ids ||= @conversation.conversation_participants.pluck(:user_id)
  end

  def find_or_create_participant(user_id)
    ConversationParticipant.find_or_create_for!(conversation: @conversation, user_id: user_id)
  end
end
