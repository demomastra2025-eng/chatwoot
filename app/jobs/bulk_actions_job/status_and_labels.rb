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
    return if accessible_links.count == communication_thread.communication_thread_conversations.count

    raise BulkActionsJob::SkippedRecord, 'Cannot update communication thread without access to all linked channels'
  end

  def bulk_add_thread_labels(accessible_links)
    return unless @params[:labels] && @params[:labels][:add]

    accessible_links.each do |link|
      link.conversation.add_labels(@params[:labels][:add])
    end
  end

  def bulk_remove_thread_labels(accessible_links)
    return unless @params[:labels] && @params[:labels][:remove]

    accessible_links.each do |link|
      labels = link.conversation.label_list - @params[:labels][:remove]
      link.conversation.update!(label_list: labels)
    end
  end
end
