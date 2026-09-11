class Conversations::RecordUserReadStateService
  UNIQUE_INDEX = 'idx_conversation_user_read_states_unique'.freeze

  def initialize(conversation:, user:)
    @conversation = conversation
    @user = user
  end

  def perform(last_seen_at: Time.current.utc)
    Conversation.transaction do
      locked_conversation = Conversation.lock.find(conversation.id)
      create_missing_account_user_baselines!(locked_conversation)
      upsert_current_user!(last_seen_at)
    end
    last_seen_at
  end

  private

  attr_reader :conversation, :user

  def create_missing_account_user_baselines!(locked_conversation)
    account_user_ids = conversation.account.account_users.pluck(:user_id)
    existing_user_ids = ConversationUserReadState.where(
      conversation_id: conversation.id,
      user_id: account_user_ids
    ).pluck(:user_id)
    missing_user_ids = account_user_ids - existing_user_ids
    return if missing_user_ids.empty?

    now = Time.current.utc
    rows = missing_user_ids.map do |user_id|
      {
        account_id: conversation.account_id,
        conversation_id: conversation.id,
        user_id: user_id,
        last_seen_at: locked_conversation.agent_last_seen_at,
        created_at: now,
        updated_at: now
      }
    end
    # Rows are derived from existing account memberships and are serialized by the conversation lock.
    ConversationUserReadState.insert_all(rows, unique_by: UNIQUE_INDEX) if rows.any? # rubocop:disable Rails/SkipsModelValidations
  end

  def upsert_current_user!(last_seen_at)
    read_state = ConversationUserReadState.find_or_initialize_by(conversation_id: conversation.id, user_id: user.id)
    read_state.account_id = conversation.account_id
    read_state.last_seen_at = last_seen_at
    read_state.save!
  end
end
