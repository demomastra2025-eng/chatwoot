module BulkActionsJob::StatusAndLabels
  def resolved_status_requested?
    Array(@params.dig(:fields, :status)).first.to_s == 'resolved'
  end

  def skip_for_missing_required_attributes!(conversation)
    custom_attributes = conversation.custom_attributes || {}
    missing = required_attribute_definitions.any? { |definition| missing_required_attribute?(definition, custom_attributes) }
    raise BulkActionsJob::SkippedRecord, 'Required conversation attributes are missing' if missing
  end

  def required_attribute_definitions
    return [] unless @account.feature_enabled?('conversation_required_attributes')

    return @required_attribute_definitions if @required_attribute_definitions

    required_keys = Array(@account.settings&.fetch('conversation_required_attributes', nil)).map(&:to_s)
    return [] if required_keys.empty?

    @required_attribute_definitions = @account.custom_attribute_definitions
                                              .conversation_attribute
                                              .where(attribute_key: required_keys)
                                              .select(:attribute_key, :attribute_display_type).to_a
  end

  def missing_required_attribute?(definition, attributes)
    key = definition.attribute_key
    present = attributes.key?(key) || attributes.key?(key.to_sym)
    return !present if definition.attribute_display_type == 'checkbox'

    value = attributes.key?(key) ? attributes[key] : attributes[key.to_sym]
    value.nil? || value.to_s.strip.empty?
  end

  def communication_thread_update_params
    params = available_params(@params) || {}
    return params unless @params[:snoozed_until]

    params.merge(snoozed_until: @params[:snoozed_until])
  end

  def status_update_params?(params)
    params.present? && params.key?(:status)
  end

  def transition_conversation_status!(conversation, params)
    status_params = params.slice(:status, :status_reason)
    status_params[:snoozed_until] = @params[:snoozed_until] if @params.key?(:snoozed_until)

    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: status_params,
      actor: @user,
      source: 'bulk_action'
    ).perform
  end

  def ensure_full_thread_accessible!(communication_thread, accessible_links)
    accessible_count = accessible_links.is_a?(Array) ? accessible_links.size : accessible_links.count
    return if accessible_count == total_link_count_for(communication_thread)

    raise ArgumentError, 'Cannot update communication thread without access to all linked channels'
  end

  # Labels belong to the person: add / remove go to the contact and to every conversation of the person, also to the
  # channels the user cannot open, and are reported once (Labels::UnifiedAssignmentService).
  def change_person_labels(contact, conversation)
    to_add = @params.dig(:labels, :add)
    to_remove = @params.dig(:labels, :remove)
    return if to_add.blank? && to_remove.blank?

    Labels::UnifiedAssignmentService.new(contact: contact, conversation: conversation, add: to_add, remove: to_remove).perform
  end
end
