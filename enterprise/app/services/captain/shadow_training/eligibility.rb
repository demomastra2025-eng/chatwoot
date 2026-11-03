# frozen_string_literal: true

class Captain::ShadowTraining::Eligibility
  KEY = 'captain_shadow_training'
  class Revoked < StandardError; end

  def self.ensure_run!(run)
    run.reload
    account = run.account.reload
    conversation = run.conversation.reload
    conversation.account = account
    run.inbound_message.reload
    allowed = allowed?(account) && run.source_owned? && human_reply?(run.human_message.reload) &&
              !Compliance::ExplicitAiConsentGate.blocked?(conversation) && actor_available?(run)
    raise Revoked, 'shadow_training_eligibility_revoked' unless allowed
  rescue ActiveRecord::RecordNotFound
    raise Revoked, 'shadow_training_source_erased'
  end

  def self.actor_available?(run)
    run.assistant.nil? || run.assistant.entry_eligible?
  end

  def self.allowed?(account)
    # Internal platform enrollment only; no customer settings or production activation by default.
    account.internal_attributes.to_h[KEY] == 'clinic'
  end

  def self.human_reply?(message)
    public_text?(message) && message.sender_type == 'User' && message.account.users.exists?(id: message.sender_id) &&
      message.conversation.account_id == message.account_id && !message.automated_outbound_message? && !imported?(message)
  end

  def self.public_text?(message)
    message.outgoing? && !message.private? && !message.failed? && message.content.present? &&
      !message.voice_call? && !message.ai_voice_transcript_turn?
  end

  def self.imported?(message)
    attributes = message.content_attributes
    !attributes.is_a?(Hash) || ActiveModel::Type::Boolean.new.cast(attributes['imported_history'])
  end
end
