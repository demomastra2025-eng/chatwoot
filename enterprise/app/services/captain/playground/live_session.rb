module Captain::Playground::LiveSession
  private

  def prepare_live!(inbox_id:, delivery_enabled:, delivery_target:)
    inbox = selected_inbox(inbox_id)
    raise ArgumentError, 'Reset the Live session before changing its inbox' if data['inbox_id'].present? && data['inbox_id'] != inbox.id

    target = configure_live_delivery!(inbox, enabled: delivery_enabled, target: delivery_target)
    data['inbox_id'] = inbox.id
    create_live_source!(inbox, target: target) if data['conversation_id'].blank?
    validate_live_source!
    update_live_profile!(target: target)
    @run_policy = nil
    conversation.update_columns(additional_attributes: conversation.additional_attributes.to_h.merge( # rubocop:disable Rails/SkipsModelValidations
      Outbound::PlaygroundDeliveryPolicy::ATTRIBUTE_KEY => run_policy
    ))
  end

  def configure_live_delivery!(inbox, enabled:, target:)
    data['delivery_enabled'] = ActiveModel::Type::Boolean.new.cast(enabled) == true
    phone = Outbound::PlaygroundDeliveryPolicy.normalize_phone(target)
    if data['delivery_enabled']
      raise ArgumentError, 'A controlled test phone number is required' unless phone
      raise ArgumentError, 'This inbox cannot deliver to a controlled phone number' unless phone_inbox?(inbox)
    end
    data['delivery_target'] = data['delivery_enabled'] ? phone : nil
    phone
  end

  def validate_live_source!
    marker = conversation.additional_attributes.to_h['captain_playground_source'].to_h
    contact_marker = conversation.contact.additional_attributes.to_h['captain_playground_source'].to_h
    raise ArgumentError, 'Live Playground requires its dedicated test caller source' unless marker == source_marker && contact_marker == source_marker
    raise ArgumentError, 'Live caller inbox changed' unless conversation.inbox_id == data['inbox_id']
  end

  def update_live_profile!(target:)
    profile = scenario.contact
    phone = updated_caller_phone(profile, target: target)
    Current.with_runtime_events_suppressed { update_native_caller!(profile, phone: phone) }
    scenario.data['caller_contact_id'] = conversation.contact_id
    profile.merge!(conversation.contact.attributes.slice(*Captain::ContextFields::CONTACT_STATE_ATTRIBUTES.map(&:to_s)))
    # Live keeps only the native caller profile. Trial identifiers/catalogues never leave its server session.
    data['scenario'] = scenario.data
  end

  def updated_caller_phone(profile, target:)
    return target if data['delivery_enabled']

    @profile_phone_edited ? profile['phone_number'] : conversation.contact.phone_number
  end

  def update_native_caller!(profile, phone:)
    conversation.contact.update!(name: profile['name'], phone_number: phone, custom_attributes: caller_custom_attributes(profile))
    return unless phone_inbox?(conversation.inbox)

    conversation.contact_inbox.update!(source_id: phone_source(conversation.inbox, phone), hmac_verified: false)
  end

  def live_payload
    return { delivery_enabled: false } unless live?

    { live_warning: Captain::Playground::Session::LIVE_WARNING, conversation_id: conversation.display_id, inbox_id: conversation.inbox_id,
      delivery_enabled: data['delivery_enabled'] == true, delivery_target: data['delivery_target'] }
  end
end
