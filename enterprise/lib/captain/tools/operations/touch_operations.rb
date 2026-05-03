class Captain::Tools::Operations::TouchOperations < Captain::Tools::Operations::BaseOperation
  SUPPORTED_REMINDABLE_KINDS = %w[conversation deal task appointment].freeze

  def create_touch(
    body: nil,
    content_kind: nil,
    template_params: nil,
    remindable_kind: nil,
    scheduled_at: nil,
    relative_anchor: nil,
    relative_offset_minutes: nil,
    timezone: nil,
    target_inbox_id: nil,
    auto_cancel_on_incoming: nil,
    attachment_ids: [],
    artifact_ids: []
  )
    normalized_template_params = parsed_hash(template_params, field_name: 'template_params')
    normalized_kind = normalized_content_kind(content_kind, template_params: normalized_template_params)
    validate_touch_content!(
      body: body,
      content_kind: normalized_kind,
      template_params: normalized_template_params,
      attachments_present: Array(attachment_ids).present? || Array(artifact_ids).present?
    )

    remindable = resolve_remindable!(remindable_kind)
    create_params = normalized_touch_params(
      body: body,
      content_kind: normalized_kind,
      template_params: normalized_template_params,
      remindable: remindable,
      scheduled_at: scheduled_at,
      relative_anchor: relative_anchor,
      relative_offset_minutes: relative_offset_minutes,
      timezone: timezone,
      target_inbox_id: target_inbox_id,
      auto_cancel_on_incoming: auto_cancel_on_incoming,
      attachment_ids: attachment_ids,
      artifact_ids: artifact_ids
    )
    delivery_policy = ensure_delivery_allowed!(create_params, remindable: remindable)
    create_params[:metadata] = (create_params[:metadata] || {}).merge('delivery_policy' => delivery_policy.as_json)

    with_idempotent_creation('create_touch', create_params.merge(remindable_gid: remindable.to_gid_param)) do
      ::Reminders::CreateService.new(
        account: account,
        remindable: remindable,
        attributes: create_params,
        creator: actor
      ).perform
    end
  end

  private

  def normalized_touch_params(
    body:,
    content_kind:,
    template_params:,
    remindable:,
    scheduled_at:,
    relative_anchor:,
    relative_offset_minutes:,
    timezone:,
    target_inbox_id:,
    auto_cancel_on_incoming:,
    attachment_ids:,
    artifact_ids:
  )
    selected_attachment_ids = materialized_attachment_ids(attachment_ids: attachment_ids, artifact_ids: artifact_ids)
    params = {
      action_type: 'send_message',
      content_kind: content_kind,
      template_params: template_params,
      text_mode: Reminders::TextModeResolver.call(
        action_type: 'send_message',
        body: body,
        instructions: nil
      ),
      timezone: timezone.presence || 'UTC',
      body: body.to_s.strip.presence,
      attachments: selected_attachment_ids,
      auto_cancel_on_incoming: auto_cancel_on_incoming.nil? || auto_cancel_on_incoming,
      target_inbox_id: target_inbox_id,
      metadata: {
        'touch_source' => 'captain',
        'captain_assistant_id' => assistant.id,
        'captain_actor_id' => actor&.id
      }.compact
    }

    effective_relative_anchor = normalized_relative_anchor(
      relative_anchor,
      relative_offset_minutes: relative_offset_minutes,
      scheduled_at: scheduled_at
    )

    if effective_relative_anchor.present?
      validate_relative_anchor!(effective_relative_anchor, remindable)
      params.merge!(
        timing_mode: 'relative',
        relative_anchor: effective_relative_anchor,
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

  def materialized_attachment_ids(attachment_ids:, artifact_ids:)
    attachment_resolver.resolve(attachment_ids: attachment_ids, artifact_ids: artifact_ids)
  end

  def normalized_content_kind(content_kind, template_params:)
    normalized = content_kind.to_s.strip
    return normalized if normalized.present?
    return 'channel_template' if template_params.present?

    'free_text'
  end

  def validate_touch_content!(body:, content_kind:, template_params:, attachments_present: false)
    case content_kind
    when 'channel_template'
      raise ArgumentError, 'template_params are required for channel_template touches' if template_params.blank?
      raise ArgumentError, 'Native attachments cannot be combined with channel_template touches' if attachments_present
    when 'free_text'
      raise ArgumentError, 'Touch body or attachment is required for free_text touches' if body.to_s.strip.blank? && !attachments_present
    else
      raise ArgumentError, 'content_kind must be one of: free_text, channel_template'
    end
  end

  def ensure_delivery_allowed!(params, remindable:)
    ::Outbound::DeliveryPolicy.ensure!(
      conversation: conversation,
      inbox: target_inbox_for_policy(params[:target_inbox_id]),
      content_kind: params[:content_kind],
      template_params: params[:template_params],
      attachments: params[:attachments],
      scheduled_at: effective_scheduled_at_for_policy(params, remindable: remindable)
    )
  end

  def effective_scheduled_at_for_policy(params, remindable:)
    return params[:scheduled_at] unless params[:timing_mode].to_s == 'relative'

    policy_probe = Reminder.new(
      account: account,
      remindable: remindable,
      conversation: conversation,
      target_inbox_id: params[:target_inbox_id],
      timing_mode: params[:timing_mode],
      relative_anchor: params[:relative_anchor],
      relative_offset_seconds: params[:relative_offset_seconds],
      timezone: params[:timezone]
    )
    policy_probe.send(:materialize_schedule)
    policy_probe.scheduled_at
  end

  def target_inbox_for_policy(target_inbox_id)
    return conversation&.inbox if target_inbox_id.blank?

    account.inboxes.find(target_inbox_id)
  end

  def attachment_resolver
    @attachment_resolver ||= Captain::Tools::AttachmentResolver.new(account: account, assistant: assistant)
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
    raise ArgumentError, "Unsupported relative_anchor: #{relative_anchor}" unless Reminder::RELATIVE_ANCHORS.include?(relative_anchor.to_s)

    return if relative_anchor.to_s == 'touch.created_at'

    entity_prefix = "#{remindable.class.name.demodulize.underscore}."
    entity_prefix = 'conversation.' if remindable.is_a?(Conversation)
    return if relative_anchor.to_s.start_with?(entity_prefix)

    raise ArgumentError, "relative_anchor #{relative_anchor} does not match the selected remindable"
  end

  def normalized_relative_anchor(relative_anchor, relative_offset_minutes:, scheduled_at:)
    return relative_anchor if relative_anchor.present?
    return 'touch.created_at' if relative_offset_minutes.present? && scheduled_at.blank?

    nil
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
