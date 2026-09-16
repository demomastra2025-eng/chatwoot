module Enterprise::Conversation
  attr_accessor :captain_activity_reason, :captain_activity_reason_type

  def captain_ai_control_active?
    !captain_human_control_active?
  end

  def captain_human_control_active?
    current_captain_control_state == Captain::Conversation::ControlService::HUMAN_CONTROL
  end

  def captain_control_owner
    communication_thread || self
  end

  def current_captain_control_state
    captain_control_owner.captain_control_state
  end

  def current_captain_control_generation
    captain_control_owner.captain_control_generation
  end

  def current_captain_handoff_applied_at
    captain_control_owner.captain_handoff_applied_at
  end

  def stamp_captain_control_generation!(message)
    captain_control_service.stamp_generation!(message)
  end

  def activate_captain_human_control!(source:, actor: nil)
    captain_control_service.activate_human!(source: source, actor: actor)
  end

  def prepare_captain_ai_control!
    captain_control_service.prepare_ai!
  end

  def with_captain_control_lock(&)
    captain_control_service.with_control_lock(&)
  end

  def publish_captain_ai_control_activated!(source:, actor: nil)
    captain_control_service.publish_ai_activated!(source: source, actor: actor)
  end

  def bot_handoff!(status_reason: nil, actor: Current.user || Current.executed_by, source: 'system', fence: nil, &)
    result = captain_control_service.handoff!(status_reason: status_reason, actor: actor, source: source, fence: fence, &)
    dispatcher_dispatch(::Conversation::CONVERSATION_BOT_HANDOFF) if result == :applied
    result
  end

  def dispatch_captain_inference_resolved_event
    dispatch_captain_inference_event(Events::Types::CONVERSATION_CAPTAIN_INFERENCE_RESOLVED)
  end

  def dispatch_captain_inference_handoff_event
    dispatch_captain_inference_event(Events::Types::CONVERSATION_CAPTAIN_INFERENCE_HANDOFF)
  end

  def list_of_keys
    super + %w[sla_policy_id]
  end

  def with_captain_activity_context(reason:, reason_type:)
    previous_reason = captain_activity_reason
    previous_reason_type = captain_activity_reason_type

    self.captain_activity_reason = reason
    self.captain_activity_reason_type = reason_type
    yield
  ensure
    self.captain_activity_reason = previous_reason
    self.captain_activity_reason_type = previous_reason_type
  end

  # Include select additional_attributes keys (call related) for update events
  def allowed_keys?
    return true if super

    attrs_change = previous_changes['additional_attributes']
    return false unless attrs_change.is_a?(Array) && attrs_change[1].is_a?(Hash)

    changed_attr_keys = attrs_change[1].keys
    changed_attr_keys.intersect?(%w[call_status])
  end

  private

  def captain_control_service
    Captain::Conversation::ControlService.new(self)
  end

  def dispatch_captain_inference_event(event_name)
    dispatcher_dispatch(event_name)
  end
end
