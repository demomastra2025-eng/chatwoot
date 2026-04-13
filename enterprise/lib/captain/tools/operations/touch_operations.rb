class Captain::Tools::Operations::TouchOperations < Captain::Tools::Operations::BaseOperation
  SUPPORTED_REMINDABLE_KINDS = %w[conversation deal task appointment].freeze

  def create_touch(
    body:,
    remindable_kind: nil,
    scheduled_at: nil,
    relative_anchor: nil,
    relative_offset_minutes: nil,
    timezone: nil,
    target_inbox_id: nil,
    auto_cancel_on_incoming: nil
  )
    raise ArgumentError, 'Touch body is required' if body.to_s.strip.blank?

    remindable = resolve_remindable!(remindable_kind)
    create_params = normalized_touch_params(
      body: body,
      remindable: remindable,
      scheduled_at: scheduled_at,
      relative_anchor: relative_anchor,
      relative_offset_minutes: relative_offset_minutes,
      timezone: timezone,
      target_inbox_id: target_inbox_id,
      auto_cancel_on_incoming: auto_cancel_on_incoming
    )

    with_idempotent_creation('create_touch', create_params.merge(remindable_gid: remindable.to_gid_param)) do
      touch = ::Reminders::CreateService.new(
        account: account,
        remindable: remindable,
        attributes: create_params,
        creator: actor
      ).perform
      touch.update!(status: :draft)
      touch
    end
  end

  private

  def normalized_touch_params(
    body:,
    remindable:,
    scheduled_at:,
    relative_anchor:,
    relative_offset_minutes:,
    timezone:,
    target_inbox_id:,
    auto_cancel_on_incoming:
  )
    params = {
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: Reminders::TextModeResolver.call(
        action_type: 'send_message',
        body: body,
        instructions: nil
      ),
      timezone: timezone.presence || 'UTC',
      body: body.to_s.strip,
      auto_cancel_on_incoming: auto_cancel_on_incoming.nil? ? true : auto_cancel_on_incoming,
      target_inbox_id: target_inbox_id,
      metadata: {
        'touch_source' => 'captain',
        'captain_assistant_id' => assistant.id,
        'captain_actor_id' => actor&.id
      }.compact
    }

    if relative_anchor.present?
      validate_relative_anchor!(relative_anchor, remindable)
      params.merge!(
        timing_mode: 'relative',
        relative_anchor: relative_anchor,
        relative_offset_seconds: parse_relative_offset_minutes(relative_offset_minutes)
      )
    else
      params.merge!(
        timing_mode: 'absolute',
        scheduled_at: parse_scheduled_at!(scheduled_at)
      )
    end

    params.compact
  end

  def resolve_remindable!(kind)
    normalized_kind = kind.to_s.presence || 'conversation'
    raise ArgumentError, "Unsupported remindable_kind: #{normalized_kind}" unless SUPPORTED_REMINDABLE_KINDS.include?(normalized_kind)

    remindable =
      case normalized_kind
      when 'conversation'
        conversation
      when 'deal'
        current_deal
      when 'task'
        current_task
      when 'appointment'
        current_appointment
      end

    raise ArgumentError, "Current #{normalized_kind} is not available" if remindable.blank?

    remindable
  end

  def validate_relative_anchor!(relative_anchor, remindable)
    unless Reminder::RELATIVE_ANCHORS.include?(relative_anchor.to_s)
      raise ArgumentError, "Unsupported relative_anchor: #{relative_anchor}"
    end

    return if relative_anchor.to_s == 'touch.created_at'

    entity_prefix = "#{remindable.class.name.demodulize.underscore}."
    entity_prefix = 'conversation.' if remindable.is_a?(Conversation)
    return if relative_anchor.to_s.start_with?(entity_prefix)

    raise ArgumentError, "relative_anchor #{relative_anchor} does not match the selected remindable"
  end

  def parse_relative_offset_minutes(value)
    return 0 if value.blank?

    Integer(value) * 60
  rescue ArgumentError, TypeError
    raise ArgumentError, 'relative_offset_minutes must be a valid integer'
  end

  def parse_scheduled_at!(value)
    raise ArgumentError, 'scheduled_at is required for absolute touches' if value.blank?

    parsed = Time.zone.parse(value.to_s)
    raise ArgumentError, 'scheduled_at must be a valid datetime' if parsed.blank?

    parsed
  end
end
