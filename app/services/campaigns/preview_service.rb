class Campaigns::PreviewService
  SAMPLE_LIMIT = 25
  TOTAL_KEYS = %w[
    deliverable
    unsupported_channel
    planned_not_implemented
    missing_target
    outside_reply_window
    requires_template
  ].freeze

  pattr_initialize [:account!, :inbox!, :audience, :message, :instructions, :text_mode, :template_params, :scheduled_at, { contact_ids: nil }]

  def call
    {
      inbox: serialized_inbox,
      capabilities: capabilities,
      audience_size: audience_size,
      deliverable_count: totals['deliverable'],
      blocked_count: audience_size - totals['deliverable'],
      totals: totals,
      sample_contacts: sample_contacts
    }
  end

  private

  def serialized_inbox
    {
      id: inbox.id,
      name: inbox.name,
      inbox_type: inbox.inbox_type,
      channel_type: inbox.display_channel_type
    }
  end

  def capabilities
    @capabilities ||= Campaigns::ChannelCapabilities.for(inbox: inbox)
  end

  def totals
    @totals ||= begin
      compute_results!
      @totals
    end
  end

  def sample_contacts
    compute_results! if @sample_contacts.nil?
    @sample_contacts
  end

  def audience_size
    @audience_size ||= audience_contacts.count
  end

  def compute_results!
    @totals = TOTAL_KEYS.index_with { 0 }
    @sample_contacts = []

    audience_contacts.find_each(batch_size: 200) do |contact|
      result = preview_contact(contact)
      @totals[result[:reason]] += 1
      @sample_contacts << result if @sample_contacts.length < SAMPLE_LIMIT
    end
  end

  def audience_contacts
    @audience_contacts ||= begin
      contacts = if contact_ids.present?
                   account.contacts.where(id: Array.wrap(contact_ids))
                 else
                   Campaigns::AudienceResolver.new(
                     account: account,
                     audience: audience
                   ).contacts
                 end

      contacts.distinct
    end
  end

  def preview_contact(contact)
    return build_result(contact, reason: 'unsupported_channel', error: capabilities[:notes].first) unless capabilities[:supports_outbound_campaigns]

    case capabilities[:delivery_readiness]
    when 'planned'
      return build_result(contact, reason: 'planned_not_implemented',
                                   error: 'Channel is planned for outbound campaigns but is not implemented in the shared runner yet.')
    when 'separate_surface'
      return build_result(contact, reason: 'unsupported_channel', error: 'This inbox uses the separate website trigger campaign surface.')
    when 'unsupported'
      return build_result(contact, reason: 'unsupported_channel',
                                   error: capabilities[:notes].first || 'Outbound campaigns are not supported for this inbox.')
    end

    target_identifier = resolve_target_identifier(contact)
    return build_result(contact, reason: 'missing_target', error: 'Contact does not have a valid target for this inbox.') if target_identifier.blank?

    if requires_open_reply_window?(contact)
      return build_result(
        contact,
        reason: 'outside_reply_window',
        target_identifier: target_identifier,
        error: 'Channel requires an active reply window before outbound delivery can start.'
      )
    end

    if requires_template?(contact)
      return build_result(
        contact,
        reason: 'requires_template',
        target_identifier: target_identifier,
        error: 'Channel requires template params outside the active reply window.'
      )
    end

    build_result(contact, reason: 'deliverable', target_identifier: target_identifier)
  end

  def resolve_target_identifier(contact)
    Campaigns::TargetResolver.new(inbox: inbox, contact: contact).resolve
  end

  def requires_template?(contact)
    return false unless capabilities[:requires_template_for_outside_window]
    return false if template_params.present?

    policy = Outbound::DeliveryPolicy.evaluate(
      conversation: latest_conversation_for(contact),
      inbox: inbox,
      content_kind: 'free_text',
      scheduled_at: scheduled_at
    )
    !policy.allowed? && policy.requires_template
  end

  def requires_open_reply_window?(contact)
    return false unless capabilities[:requires_open_reply_window]

    conversation = latest_conversation_for(contact)
    conversation.blank? || !conversation.can_reply?
  end

  def latest_conversation_for(contact)
    inbox.conversations
         .where(contact: contact)
         .joins(:messages)
         .where(messages: { message_type: Message.message_types[:incoming] })
         .distinct
         .order(last_activity_at: :desc)
         .first
  end

  def build_result(contact, reason:, target_identifier: nil, error: nil)
    {
      id: contact.id,
      name: contact.name,
      phone_number: contact.phone_number,
      email: contact.email,
      deliverable: reason == 'deliverable',
      reason: reason,
      target_identifier: target_identifier,
      error: error
    }
  end
end
