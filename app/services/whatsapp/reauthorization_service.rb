class Whatsapp::ReauthorizationService
  class PhoneNumberMismatchError < ArgumentError; end
  class IdentityMismatchError < ArgumentError; end

  def self.resolve_identifier(persisted_value, requested_value)
    return requested_value if persisted_value.blank?
    return persisted_value if requested_value.blank? || requested_value.to_s == persisted_value.to_s

    raise IdentityMismatchError, 'WhatsApp reauthorization identity does not match the existing channel'
  end

  def initialize(**params)
    @account = params.fetch(:account)
    @inbox_id = params.fetch(:inbox_id)
    @phone_number_id = params.fetch(:phone_number_id)
    @business_id = params.fetch(:business_id)
    @waba_id = params.fetch(:waba_id)
    @signup_type = params.fetch(:signup_type, 'standard')
  end

  def perform(access_token, phone_info, &)
    inbox = @account.inboxes.find(@inbox_id)
    channel = inbox.channel

    validate_channel_identity!(channel, phone_info)

    current_waba_id = channel.provider_config.to_h['business_account_id']
    Whatsapp::WabaLock.with_locks([current_waba_id, @waba_id]) do
      ActiveRecord::Base.transaction do
        update_channel_config(channel, access_token, phone_info)
      end
      yield channel if block_given?
    end

    channel
  end

  private

  def validate_channel_identity!(channel, phone_info)
    raise PhoneNumberMismatchError, 'Phone number does not match the existing WhatsApp channel' if phone_info[:phone_number] != channel.phone_number

    validate_provider_identity!(channel)
  end

  def validate_provider_identity!(channel)
    current_config = channel.provider_config.to_h
    identifiers = {
      'phone_number_id' => @phone_number_id,
      'business_account_id' => @waba_id,
      'business_id' => @business_id
    }
    mismatch = identifiers.any? do |key, value|
      current_config[key].present? && value.present? && current_config[key].to_s != value.to_s
    end
    return unless mismatch

    raise IdentityMismatchError, 'WhatsApp reauthorization identity does not match the existing channel'
  end

  def update_channel_config(channel, access_token, phone_info)
    channel.with_lock do
      channel.reload
      validate_channel_identity!(channel, phone_info)
      current_config = channel.provider_config.to_h.except('authorization_status', 'authorization_error')
      channel.provider_config = current_config.merge(authorization_config(access_token, current_config))
                                              .merge(capability_config(phone_info, current_config))
      channel.save!
    end

    # Update inbox name if business name changed
    business_name = phone_info[:business_name] || phone_info[:verified_name]
    channel.inbox.update!(name: business_name) if business_name.present?
  end

  def capability_config(phone_info, current_config)
    config = {
      'calling_capable' => phone_info[:calling_capable],
      'calling_capabilities' => phone_info[:calling_capabilities]
    }.compact
    config['calling_enabled'] = true if phone_info[:calling_capable] && !current_config.key?('calling_enabled')
    config
  end

  def authorization_config(access_token, current_config)
    config = {
      'api_key' => access_token,
      'phone_number_id' => @phone_number_id,
      'business_account_id' => @waba_id,
      'business_id' => @business_id,
      'source' => 'embedded_signup',
      'embedded_signup_flow' => @signup_type
    }.compact
    config['coexistence_sync'] = coexistence_sync_config(current_config) if @signup_type == 'coexistence'
    config
  end

  def coexistence_sync_config(current_config)
    current = current_config['coexistence_sync'].to_h
    if current.present? && %w[failed manual_recovery_required].exclude?(current['state'])
      return current.merge('generation' => current['generation'].presence || SecureRandom.uuid)
    end

    now = Time.current
    {
      'generation' => SecureRandom.uuid,
      'state' => 'pending',
      'onboarded_at' => now.iso8601,
      'deadline_at' => (now + 24.hours).iso8601
    }
  end
end
