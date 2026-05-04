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

  def cancel_touch(touch_id:, reason: nil)
    touch = find_touch!(touch_id)

    touch.with_lock do
      return touch if touch.cancelled?

      raise ArgumentError, 'Touch can only be cancelled while draft or pending' unless touch.draft? || touch.pending?

      cancellation_reason = reason.presence || 'Cancelled by Captain'
      touch.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        last_error: cancellation_reason,
        metadata: touch.metadata.to_h.merge(cancellation_metadata(cancelled_via: 'captain_cancel_touch', reason: cancellation_reason))
      )
      touch
    end
  end

  def delete_touch(touch_id:)
    touch = find_touch!(touch_id)
    raise ArgumentError, 'Only draft, pending, failed, or cancelled touches can be deleted' unless touch.destroyable?

    payload = ::Outbound::PayloadBuilder.touch_payload(touch)
    touch.destroy!
    payload
  end

  def cancel_touches(remindable_kind: nil, touch_plan_id: nil, touch_plan_name: nil, reason: nil)
    normalized_kind = normalized_remindable_kind(remindable_kind)
    remindable = resolve_remindable!(normalized_kind)
    touch_plan = find_optional_touch_plan!(touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)
    ensure_touch_plan_supports!(touch_plan, normalized_kind) if touch_plan.present?
    cancellation_reason = reason.presence || 'Cancelled by Captain'

    cancelled_count = ::Reminders::BulkCancelService.new(
      account: account,
      remindable: remindable,
      reminder_group: touch_plan,
      actor: actor,
      reason: cancellation_reason,
      metadata: cancellation_metadata(cancelled_via: 'captain_cancel_touches', reason: cancellation_reason).merge(
        'cancel_touches_entity_kind' => normalized_kind,
        'touch_plan_id' => touch_plan&.id
      ).compact
    ).perform

    {
      cancelled_count: cancelled_count,
      remindable: ::Outbound::PayloadBuilder.remindable_payload(remindable),
      touch_plan: touch_plan ? ::Outbound::PayloadBuilder.touch_plan_payload(touch_plan) : nil
    }
  end

  def create_touch_plan(name:, touches:, description: nil, entity_kinds: nil)
    normalized_name = name.to_s.strip
    raise ArgumentError, 'Touch plan name is required' if normalized_name.blank?

    create_params = {
      name: normalized_name,
      description: description.presence,
      entity_kinds: normalized_plan_entity_kinds(entity_kinds),
      touches: normalized_touch_definitions(touches)
    }.compact

    with_idempotent_creation('create_touch_plan', create_params) do
      account.reminder_groups.create!(create_params.merge(creator: actor))
    end
  end

  def apply_touch_plan(touch_plan_id: nil, touch_plan_name: nil, remindable_kind: nil)
    normalized_kind = normalized_remindable_kind(remindable_kind)
    remindable = resolve_remindable!(normalized_kind)
    touch_plan = find_kept_touch_plan!(touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)
    ensure_touch_plan_supports!(touch_plan, normalized_kind)

    created_touches = ::Reminders::ApplyGroupService.new(
      account: account,
      reminder_group: touch_plan,
      remindable: remindable,
      actor: actor
    ).perform
    tag_created_plan_touches!(created_touches, touch_plan)
    created_touches
  end

  def archive_touch_plan(touch_plan_id: nil, touch_plan_name: nil)
    touch_plan = find_touch_plan!(touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)
    touch_plan.archive! if touch_plan.archived_at.blank? || touch_plan.active?
    touch_plan
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

  def find_touch!(touch_id)
    raise ArgumentError, 'touch_id is required' if touch_id.blank?

    account.reminders.find(touch_id)
  end

  def find_touch_plan!(touch_plan_id: nil, touch_plan_name: nil)
    scope = account.reminder_groups
    touch_plan = find_touch_plan_in_scope(scope, touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)
    raise ActiveRecord::RecordNotFound, 'Touch plan not found' if touch_plan.blank?

    touch_plan
  end

  def find_kept_touch_plan!(touch_plan_id: nil, touch_plan_name: nil)
    scope = account.reminder_groups.kept
    touch_plan = find_touch_plan_in_scope(scope, touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)
    raise ActiveRecord::RecordNotFound, 'Touch plan not found' if touch_plan.blank?

    touch_plan
  end

  def find_optional_touch_plan!(touch_plan_id: nil, touch_plan_name: nil)
    return if touch_plan_id.blank? && touch_plan_name.blank?

    find_kept_touch_plan!(touch_plan_id: touch_plan_id, touch_plan_name: touch_plan_name)
  end

  def find_touch_plan_in_scope(scope, touch_plan_id:, touch_plan_name:)
    return scope.find_by(id: touch_plan_id) if touch_plan_id.present?
    return if touch_plan_name.blank?

    scope.where('LOWER(name) = ?', touch_plan_name.to_s.strip.downcase).order(:id).first
  end

  def ensure_touch_plan_supports!(touch_plan, entity_kind)
    return if touch_plan.entity_kind_supported?(entity_kind)

    raise ArgumentError, 'Touch plan does not support this entity kind'
  end

  def normalized_plan_entity_kinds(entity_kinds)
    values = parsed_array(entity_kinds, field_name: 'entity_kinds')
    values = ['conversation'] if values.blank?
    values.map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def normalized_touch_definitions(touches)
    definitions = parsed_array(touches, field_name: 'touches')
    raise ArgumentError, 'Touch plan touches are required' if definitions.blank?

    definitions.map do |definition|
      raise ArgumentError, 'Each touch plan item must be an object' unless definition.respond_to?(:to_h)

      ::Reminders::DefinitionNormalizer.call(definition.to_h)
    end
  end

  def parsed_array(value, field_name:)
    return [] if value.blank?
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON array" unless parsed.is_a?(Array)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def tag_created_plan_touches!(touches, touch_plan)
    touches.each do |touch|
      touch.update!(
        metadata: touch.metadata.to_h.merge(
          'touch_source' => 'captain',
          'captain_assistant_id' => assistant.id,
          'captain_actor_id' => actor&.id,
          'captain_touch_plan_id' => touch_plan.id
        ).compact
      )
    end
  end

  def cancellation_metadata(cancelled_via:, reason:)
    {
      'touch_source' => 'captain',
      'captain_assistant_id' => assistant.id,
      'captain_actor_id' => actor&.id,
      'cancelled_via' => cancelled_via,
      'cancelled_reason' => reason,
      'cancelled_at' => Time.current.iso8601,
      'cancelled_by_type' => actor&.class&.name,
      'cancelled_by_id' => actor&.id
    }.compact
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
    normalized_kind = normalized_remindable_kind(kind)

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

  def normalized_remindable_kind(kind)
    normalized_kind = kind.to_s.presence || 'conversation'
    raise ArgumentError, "Unsupported remindable_kind: #{normalized_kind}" unless SUPPORTED_REMINDABLE_KINDS.include?(normalized_kind)

    normalized_kind
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
