# Tells the other operators of the account that an operator is calling the
# client of a conversation (or talking to them) and when that stops.
# Only users of the same account that the conversation policy lets see the
# conversation get the event (members of the inbox and of its team and
# administrators, custom roles included), never the operator himself.
class Telephony::OperatorActivityBroadcaster
  def initialize(call_session:)
    @call_session = call_session
  end

  def perform
    activity = Telephony::OperatorActivity.new(call_session)
    payload = activity.payload
    return if payload.blank?

    tokens = pubsub_tokens(activity.operator)
    return if tokens.blank?

    event = { event: Telephony::OperatorActivity::EVENT, data: payload }
    tokens.each { |token| ActionCable.server.broadcast(token, event) }
  rescue StandardError => e
    Rails.logger.warn(
      'TELEPHONY_OPERATOR_ACTIVITY_BROADCAST_FAILED ' \
      "call_ref=#{call_session&.external_call_ref} account_id=#{call_session&.account_id} error=#{e.class.name}: #{e.message}"
    )
  end

  private

  attr_reader :call_session

  def pubsub_tokens(operator)
    account = call_session.account
    inbox = call_session.inbox
    conversation = call_session.conversation
    return [] if inbox.blank? || inbox.account_id != account.id
    return [] if conversation.blank? || conversation.account_id != account.id

    candidates = (inbox.members.to_a + Array(conversation.team&.members&.to_a) + account.administrators.to_a).uniq
    account_users = account.account_users.where(user_id: candidates.map(&:id)).index_by(&:user_id)

    candidates.filter_map do |user|
      account_user = account_users[user.id]
      next if user.id == operator.id || account_user.blank?

      user.pubsub_token if can_see_conversation?(user, account, account_user, conversation)
    end
  end

  # The rule of the operator_activity endpoint: the conversation policy.
  def can_see_conversation?(user, account, account_user, conversation)
    ConversationPolicy.new({ user: user, account: account, account_user: account_user }, conversation).show?
  end
end
