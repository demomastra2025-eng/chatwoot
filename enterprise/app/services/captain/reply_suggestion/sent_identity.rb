# frozen_string_literal: true

# The financial write is part of the primary Message save, independent of optional feedback/Redis.
class Captain::ReplySuggestion::SentIdentity
  class OwnershipError < StandardError; end

  def self.attributes(request_id:, account:, conversation:, user:)
    raise OwnershipError, I18n.t('captain.reply_suggestion.errors.not_found') unless accessible?(account, conversation, user)

    identity = Captain::ReplySuggestion::Identity.owned!(request_id: request_id, account: account, conversation: conversation, user: user)
    { 'captain_ai_suggestion' => { 'request_id' => identity.request_id } }
  rescue ActiveRecord::RecordNotFound
    raise OwnershipError, I18n.t('captain.reply_suggestion.errors.not_found')
  end

  def self.accessible?(account, conversation, user)
    return false unless user.is_a?(User) && conversation.account_id == account.id

    membership = AccountUser.find_by(account_id: account.id, user_id: user.id)
    membership && ConversationPolicy.new({ user: user, account: account, account_user: membership }, conversation).show?
  end
  private_class_method :accessible?
end
