# The service keeps identity proof, row-lock CAS, and callback phases ordered.
class Whatsapp::ReauthorizationService # rubocop:disable Metrics/ClassLength
  class PhoneNumberMismatchError < ArgumentError; end
  class IdentityMismatchError < ArgumentError; end

  class CallbackAuthorizationStateChangedError < ArgumentError
    def initialize
      super('WhatsApp authorization changed during callback setup. Retry the connection.')
    end
  end

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
    @identity_resolution = params[:identity_resolution]
  end

  def perform(access_token, phone_info, &)
    inbox = @account.inboxes.find(@inbox_id)
    raise ActiveRecord::RecordNotFound if inbox.deleting_at.present?

    channel = inbox.channel
    validate_inbox_context!(inbox, channel)
    validate_channel_identity!(channel, access_token, phone_info, inbox: inbox)
    @expected_provider_config = channel.provider_config.to_h.deep_dup
    @provider_config_to_persist = prepare_provider_config(channel, access_token, phone_info, @expected_provider_config)

    current_waba_id = channel.provider_config.to_h['business_account_id']
    Whatsapp::WabaLock.with_locks([current_waba_id, @waba_id]) do
      ActiveRecord::Base.transaction do
        locked_inbox = @account.inboxes.lock.find(@inbox_id)
        validate_inbox_context!(locked_inbox, channel)
        update_channel_config(channel, access_token, phone_info, locked_inbox)
      end
      yield channel if block_given?
    end

    channel
  end

  private

  def validate_inbox_context!(inbox, channel)
    raise IdentityMismatchError, 'WhatsApp reauthorization target changed' if inbox.deleting_at.present?
    raise IdentityMismatchError, 'WhatsApp reauthorization target changed' unless inbox.account_id == @account.id
    raise IdentityMismatchError, 'WhatsApp reauthorization target changed' unless inbox.channel_id == channel.id
    raise IdentityMismatchError, 'WhatsApp reauthorization target changed' unless channel.account_id == @account.id
    raise IdentityMismatchError, 'WhatsApp reauthorization target changed' unless channel.provider == 'whatsapp_cloud'
  end

  def validate_channel_identity!(channel, access_token, phone_info, inbox:)
    phone_matches = if identity_migration?
                      Whatsapp::ReauthorizationIdentityResolver.normalize_phone(phone_info[:phone_number]) ==
                        Whatsapp::ReauthorizationIdentityResolver.normalize_phone(channel.phone_number)
                    else
                      phone_info[:phone_number].to_s == channel.phone_number.to_s
                    end
    raise PhoneNumberMismatchError, 'Phone number does not match the existing WhatsApp channel' unless phone_matches

    if identity_migration?
      validate_identity_resolution!(channel, access_token, phone_info, inbox)
      validate_target_asset_ownership!(channel)
    else
      validate_provider_identity!(channel)
    end
  end

  def validate_identity_resolution!(channel, access_token, phone_info, inbox)
    current_config = channel.provider_config.to_h
    proof = @identity_resolution
    valid_proof = proof.is_a?(Whatsapp::ReauthorizationIdentityResolver::Resolution) &&
                  proof.valid_for?(
                    account_id: @account.id,
                    inbox_id: @inbox_id,
                    channel: channel,
                    current_identity: current_config,
                    target_identity: target_identity,
                    signup_type: @signup_type,
                    access_token: access_token,
                    phone_info: phone_info
                  )
    valid_source = current_config['source'] == 'embedded_signup' &&
                   current_config['embedded_signup_flow'].to_s == @signup_type.to_s &&
                   inbox&.id.to_s == @inbox_id.to_s
    raise IdentityMismatchError, 'WhatsApp reauthorization identity does not match the existing channel' unless valid_proof && valid_source
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

  def validate_target_asset_ownership!(channel)
    siblings = Channel::Whatsapp.lifecycle_cloud.where.not(id: channel.id)
    foreign_waba_owner = siblings.for_waba(@waba_id).where.not(account_id: @account.id).exists?
    phone_id_owner = siblings.exists?(["provider_config ->> 'phone_number_id' = ?", @phone_number_id.to_s])
    same_account_coexistence_owner = @signup_type == 'coexistence' &&
                                     siblings.for_waba(@waba_id).where(account_id: @account.id)
                                             .where("provider_config ->> 'embedded_signup_flow' = 'coexistence'").exists?
    return unless foreign_waba_owner || phone_id_owner || same_account_coexistence_owner

    raise IdentityMismatchError, 'WhatsApp reauthorization identity does not match the existing channel'
  end

  def update_channel_config(channel, access_token, phone_info, inbox)
    channel.with_lock do
      channel.reload
      validate_inbox_context!(inbox, channel)
      validate_channel_identity!(channel, access_token, phone_info, inbox: inbox)
      unless provider_config_matches?(channel.provider_config, @expected_provider_config)
        raise IdentityMismatchError, 'WhatsApp reauthorization target changed'
      end

      channel.provider_config = @provider_config_to_persist.deep_dup
      channel.errors.clear
      Whatsapp::WabaRoutingOwnershipValidator.new(channel).validate
      raise ActiveRecord::RecordInvalid, channel if channel.errors.any?

      channel.update_columns(provider_config: @provider_config_to_persist, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Identity recovery keeps the user's chosen inbox name unchanged.
    return if identity_migration?

    business_name = phone_info[:business_name] || phone_info[:verified_name]
    channel.inbox.update!(name: business_name) if business_name.present?
  end

  def prepare_provider_config(channel, access_token, phone_info, current_config)
    updated_config = current_config.to_h.deep_dup
                                   .merge(authorization_config(access_token, current_config))
                                   .merge(capability_config(phone_info, current_config))
    updated_config['webhook_verify_token'] ||= SecureRandom.hex(16) if channel.provider == 'whatsapp_cloud'

    # Channel::Whatsapp's model validation performs a remote GET and records
    # failures on the channel. This pure GET validates the candidate token
    # without changing provider state before the row-locked compare-and-write.
    begin
      valid_credentials = Whatsapp::FacebookApiClient.new(access_token)
                                                     .validate_waba_message_templates_access(@waba_id)
    rescue Whatsapp::FacebookApiClient::Error
      valid_credentials = false
    end
    unless valid_credentials
      channel.errors.clear
      channel.errors.add(:provider_config, 'Invalid Credentials')
      raise ActiveRecord::RecordInvalid.new(channel), cause: nil
    end

    channel.reload
    raise IdentityMismatchError, 'WhatsApp reauthorization target changed' unless provider_config_matches?(channel.provider_config, current_config)

    updated_config
  end

  def provider_config_matches?(left, right)
    left.to_h.deep_stringify_keys == right.to_h.deep_stringify_keys
  end

  def target_identity
    {
      'business_account_id' => @waba_id,
      'phone_number_id' => @phone_number_id,
      'business_id' => @business_id,
      'source' => 'embedded_signup',
      'embedded_signup_flow' => @signup_type
    }
  end

  def identity_migration?
    @identity_resolution&.identity_changed? == true
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
    if @signup_type == 'coexistence'
      if identity_migration?
        config['coexistence_sync'] = current_config['coexistence_sync'] if current_config.key?('coexistence_sync')
      else
        config['coexistence_sync'] = coexistence_sync_config(current_config)
      end
    end
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
