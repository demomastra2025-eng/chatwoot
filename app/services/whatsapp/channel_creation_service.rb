class Whatsapp::ChannelCreationService
  def initialize(account, waba_info, phone_info, access_token, signup_type: 'standard')
    @account = account
    @waba_info = waba_info
    @phone_info = phone_info
    @access_token = access_token
    @signup_type = signup_type
  end

  def perform
    validate_parameters!

    Whatsapp::WabaLock.new(@waba_info[:waba_id]).with_lock do
      existing_channel = find_existing_channel
      raise I18n.t('errors.whatsapp.phone_number_already_exists', phone_number: existing_channel.phone_number) if existing_channel

      create_channel_with_inbox
    end
  end

  private

  def validate_parameters!
    raise ArgumentError, 'Account is required' if @account.blank?
    raise ArgumentError, 'WABA info is required' if @waba_info.blank?
    raise ArgumentError, 'Phone info is required' if @phone_info.blank?
    raise ArgumentError, 'Access token is required' if @access_token.blank?
  end

  def find_existing_channel
    Channel::Whatsapp.find_by(
      phone_number: @phone_info[:phone_number]
    )
  end

  def create_channel_with_inbox
    ActiveRecord::Base.transaction do
      channel = build_channel
      create_inbox(channel)
      channel
    end
  end

  def build_channel
    Channel::Whatsapp.build(
      account: @account,
      phone_number: @phone_info[:phone_number],
      provider: 'whatsapp_cloud',
      provider_config: build_provider_config
    )
  end

  def build_provider_config
    {
      api_key: @access_token,
      phone_number_id: @phone_info[:phone_number_id],
      business_account_id: @waba_info[:waba_id],
      business_id: @waba_info[:business_id],
      source: 'embedded_signup',
      embedded_signup_flow: @signup_type,
      calling_capable: @phone_info[:calling_capable],
      calling_capabilities: @phone_info[:calling_capabilities]
    }.compact.tap do |config|
      config[:calling_enabled] = true if @phone_info[:calling_capable]
      config[:coexistence_sync] = coexistence_sync_config if @signup_type == 'coexistence'
    end
  end

  def coexistence_sync_config
    now = Time.current
    {
      generation: SecureRandom.uuid,
      state: 'pending',
      onboarded_at: now.iso8601,
      deadline_at: (now + 24.hours).iso8601
    }
  end

  def create_inbox(channel)
    inbox_name = build_inbox_name

    Inbox.create!(
      account: @account,
      name: inbox_name,
      channel: channel
    )
  end

  def build_inbox_name
    business_name = @phone_info[:business_name] || @waba_info[:business_name]
    "#{business_name} WhatsApp"
  end
end
