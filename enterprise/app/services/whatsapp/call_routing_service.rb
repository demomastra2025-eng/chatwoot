class Whatsapp::CallRoutingService
  Decision = Data.define(:action, :reason, :conversation_status, :assistant) do
    def ai?
      action == 'ai_accept'
    end

    def human?
      action == 'human_ring'
    end

    def reject?
      action == 'reject'
    end
  end

  pattr_initialize [:call!]

  def perform
    case conversation_status
    when 'open'
      human_decision(reason: 'conversation_open_operator_owns_call')
    when 'pending'
      return human_decision(reason: 'conversation_pending_captain_missing') if assistant.blank?
      return ai_decision if ai_voice_enabled?

      human_decision(reason: 'conversation_pending_ai_voice_disabled')
    else
      human_decision(reason: "conversation_#{conversation_status.presence || 'unknown'}_fail_safe_human")
    end
  end

  private

  def ai_decision
    Decision.new(
      action: 'ai_accept',
      reason: 'conversation_pending_ai_voice_enabled',
      conversation_status: conversation_status,
      assistant: assistant
    )
  end

  def human_decision(reason:)
    Decision.new(
      action: 'human_ring',
      reason: reason,
      conversation_status: conversation_status,
      assistant: assistant
    )
  end

  def conversation_status
    @conversation_status ||= call.conversation&.status.to_s
  end

  def assistant
    @assistant ||= call.inbox&.captain_assistant
  end

  def ai_voice_enabled?
    return false if assistant.blank?

    ActiveModel::Type::Boolean.new.cast(provider_config['ai_voice_enabled'])
  end

  def provider_config
    @provider_config ||= call.inbox&.channel&.provider_config.to_h.with_indifferent_access
  end
end
