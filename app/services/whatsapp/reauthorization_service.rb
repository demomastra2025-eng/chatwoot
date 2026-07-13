class Whatsapp::ReauthorizationService
  def initialize(account:, inbox_id:, phone_number_id:, business_id:, waba_id:)
    @account = account
    @inbox_id = inbox_id
    @phone_number_id = phone_number_id
    @business_id = business_id
    @waba_id = waba_id
  end

  def perform(access_token, phone_info)
    inbox = @account.inboxes.find(@inbox_id)
    channel = inbox.channel

    # Validate phone number matches for reauthorization
    if phone_info[:phone_number] != channel.phone_number
      raise StandardError, "Phone number mismatch. Expected #{channel.phone_number}, got #{phone_info[:phone_number]}"
    end

    # Update channel configuration
    update_channel_config(channel, access_token, phone_info)

    channel
  end

  private

  def update_channel_config(channel, access_token, phone_info)
    channel.with_lock do
      channel.reload
      current_config = channel.provider_config.to_h.except(*Channel::Whatsapp::AUTHORIZATION_FAILURE_CONFIG_KEYS)
      capability_config = {
        'calling_capable' => phone_info[:calling_capable],
        'calling_capabilities' => phone_info[:calling_capabilities]
      }.compact
      capability_config['calling_enabled'] = true if phone_info[:calling_capable] && !current_config.key?('calling_enabled')

      channel.provider_config = current_config.merge(
        'api_key' => access_token,
        'phone_number_id' => @phone_number_id,
        'business_account_id' => @waba_id,
        'business_id' => @business_id,
        'source' => 'embedded_signup'
      ).merge(capability_config)
      channel.save!
    end

    # Update inbox name if business name changed
    business_name = phone_info[:business_name] || phone_info[:verified_name]
    channel.inbox.update!(name: business_name) if business_name.present?
  end
end
