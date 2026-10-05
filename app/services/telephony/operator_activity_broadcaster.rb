# Tells the other operators of the account that an operator is calling the
# client of a conversation (or talking to them) and when that stops.
# Only users of the same account that can see the conversation get the event
# (members of the inbox and administrators), never the operator himself.
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
    return [] if inbox.blank? || inbox.account_id != account.id

    user_ids = inbox.inbox_members.pluck(:user_id) + account.administrators.pluck(:id)
    account.users.where(id: user_ids.uniq).where.not(id: operator.id).filter_map(&:pubsub_token)
  end
end
