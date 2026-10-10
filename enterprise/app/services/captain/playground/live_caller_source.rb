module Captain::Playground::LiveCallerSource
  private

  def source_marker
    { 'session_id' => id, 'account_id' => account.id, 'user_id' => user.id, 'assistant_id' => assistant.id }
  end

  def create_live_source!(inbox, target:)
    profile = scenario.contact
    phone = initial_caller_phone(profile, target: target)
    source = phone_inbox?(inbox) ? phone_source(inbox, phone) : "captain-playground-#{id}"
    account.with_lock do
      Current.with_runtime_events_suppressed do
        contact = create_native_caller!(profile, phone: phone)
        @conversation = create_native_conversation!(contact, inbox: inbox, source: source)
        data['caller_contact_id'] = contact.id
        data['conversation_id'] = @conversation.id
      end
    end
  end

  def initial_caller_phone(profile, target:)
    return target if data['delivery_enabled']
    return profile['phone_number'] if @profile_phone_edited

    seed = Digest::SHA256.hexdigest(id).to_i(16).to_s.last(12).rjust(12, '0')
    "+999#{seed}"
  end

  def create_native_caller!(profile, phone:)
    contact = account.contacts.build(name: profile['name'], phone_number: phone, identifier: "captain-playground-#{id}",
                                     email: nil, custom_attributes: caller_custom_attributes(profile),
                                     additional_attributes: { 'captain_playground_source' => source_marker })
    contact.skip_runtime_events = true
    contact.save!
    contact
  end

  def create_native_conversation!(contact, inbox:, source:)
    contact_inbox = contact.contact_inboxes.create!(inbox: inbox, source_id: source, hmac_verified: false)
    record = account.conversations.build(inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                         status: :pending, additional_attributes: { 'captain_playground_source' => source_marker })
    record.skip_runtime_events = true
    record.skip_communication_thread_refresh = true
    record.save!
    record
  end

  def phone_inbox?(inbox)
    Outbound::PlaygroundDeliveryPolicy::PHONE_CHANNELS.include?(inbox.channel_type)
  end

  def phone_source(inbox, phone)
    return phone if inbox.channel_type == 'Channel::Sms'
    return phone.delete_prefix('+') unless inbox.channel_type == 'Channel::TwilioSms'

    inbox.channel.medium == 'whatsapp' ? "whatsapp:#{phone}" : phone
  end

  def caller_custom_attributes(profile)
    profile['custom_attributes'].to_h.reject { |key, _value| key.match?(/medelement|provider|verified|captain_playground/i) }
  end
end
