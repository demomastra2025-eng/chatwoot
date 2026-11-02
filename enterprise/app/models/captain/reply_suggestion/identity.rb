# frozen_string_literal: true

# Ownership proof for a generated draft. No patient text, prompt or generated content.
class Captain::ReplySuggestion::Identity < ApplicationRecord
  self.table_name = 'captain_reply_suggestion_identities'
  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :user, class_name: '::User'

  def self.register!(record)
    owner = record.slice('account_id', 'conversation_id', 'user_id')
    identity = create_or_find_by!(request_id: record.fetch('id')) do |row|
      row.assign_attributes(owner.merge(generated_at: Time.current))
    end
    raise ArgumentError, 'Suggestion ownership is immutable' unless identity.attributes.slice(*owner.keys) == owner

    identity
  end

  def self.owned!(request_id:, account:, conversation:, user:)
    find_by!(request_id: request_id, account_id: account.id, conversation_id: conversation.id, user_id: user.id)
  end
end
