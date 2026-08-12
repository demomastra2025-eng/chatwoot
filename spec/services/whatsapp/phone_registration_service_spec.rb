require 'rails_helper'

RSpec.describe Whatsapp::PhoneRegistrationService do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      provider_config: {
        'api_key' => 'access-token',
        'business_account_id' => 'waba-1',
        'phone_number_id' => 'phone-1',
        'verification_pin' => '111111'
      },
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }
  let(:service) { described_class.new(channel, api_client: api_client) }
  let(:phone_number_id) { channel.provider_config['phone_number_id'] }

  def provider_error(code)
    response = instance_double(
      HTTParty::Response,
      parsed_response: { 'error' => { 'code' => code } },
      code: 400,
      body: { error: { code: code } }.to_json
    )
    Whatsapp::FacebookApiClient::Error.new('Phone registration failed', response)
  end

  it 'stores the PIN only after Meta confirms registration' do
    expect(api_client).to receive(:register_phone_number).with(phone_number_id, '012345') do
      config = channel.reload.provider_config
      expect(config['verification_pin']).to eq('111111')
      expect(config.dig(described_class::CONFIG_KEY, described_class::PENDING_PIN_CIPHERTEXT_KEY)).to be_present
      expect(config.to_json).not_to include('012345')
    end.and_return('success' => true)

    expect(service.perform(pin: '012345')).to be(true)
    expect(channel.reload.provider_config).to include('verification_pin' => '012345')
    expect(channel.provider_config.fetch(described_class::CONFIG_KEY)).to include(
      'status' => 'registered',
      'attempt_count' => 1
    )
  end

  it 'removes the pending PIN ciphertext after Meta confirms registration' do
    allow(api_client).to receive(:register_phone_number).and_return('success' => true)

    service.perform(pin: '012345')

    expect(channel.reload.provider_config.dig(described_class::CONFIG_KEY, described_class::PENDING_PIN_CIPHERTEXT_KEY)).to be_nil
  end

  it 'maps Meta 133005 to a durable PIN mismatch without storing the rejected PIN' do
    allow(api_client).to receive(:register_phone_number).and_raise(provider_error(133_005))

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('pin_incorrect') }

    expect(channel.reload.provider_config).not_to have_key('verification_pin')
    expect(channel.provider_config.fetch(described_class::CONFIG_KEY)).to include(
      'status' => 'pin_incorrect',
      'provider_error_code' => 133_005
    )
  end

  it 'maps Meta 133006 to the phone-verification lifecycle' do
    allow(api_client).to receive(:register_phone_number).and_raise(provider_error(133_006))

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('phone_verification_required') }
  end

  it 'maps Meta 133016 and blocks another provider request until the local cooldown expires' do
    allow(api_client).to receive(:register_phone_number).once.and_raise(provider_error(133_016))

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('rate_limited') }
    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.provider_code).to eq(133_016) }
  end

  it 'blocks an eleventh attempt inside the rolling 72-hour window' do
    attempts = Array.new(10) { |index| (71.hours.ago + index.minutes).iso8601 }
    config = channel.provider_config.merge(
      described_class::CONFIG_KEY => {
        'status' => 'pin_incorrect',
        'attempt_count' => 10,
        'attempt_timestamps' => attempts
      }
    )
    channel.persist_provider_config_state!(config)
    expect(api_client).not_to receive(:register_phone_number)

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('rate_limited') }

    expect(channel.reload.provider_config.dig(described_class::CONFIG_KEY, 'retry_after_at')).to be_present
  end

  it 'expires only attempts outside the rolling window' do
    attempts = [73.hours.ago.iso8601] + Array.new(9) { |index| (71.hours.ago + index.minutes).iso8601 }
    channel.persist_provider_config_state!(
      channel.provider_config.merge(
        described_class::CONFIG_KEY => { 'status' => 'pin_incorrect', 'attempt_timestamps' => attempts }
      )
    )
    allow(api_client).to receive(:register_phone_number).and_raise(provider_error(133_005))

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('pin_incorrect') }

    stored_attempts = channel.reload.provider_config.dig(described_class::CONFIG_KEY, 'attempt_timestamps')
    expect(stored_attempts.size).to eq(10)
    expect(stored_attempts).not_to include(attempts.first)
  end

  it 'keeps an unknown outcome separate and does not persist the submitted PIN' do
    allow(api_client).to receive(:register_phone_number).and_raise(Timeout::Error, 'timed out')

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('outcome_unknown') }

    expect(channel.reload.provider_config['verification_pin']).to eq('111111')
    expect(channel.provider_config.dig(described_class::CONFIG_KEY, 'status')).to eq('outcome_unknown')
    ciphertext = channel.provider_config.dig(described_class::CONFIG_KEY, described_class::PENDING_PIN_CIPHERTEXT_KEY)
    expect(ciphertext).to be_present
    expect(ciphertext).not_to include('654321')
  end

  it 'blocks a manual retry while a provider outcome is unknown' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge(described_class::CONFIG_KEY => { 'status' => 'outcome_unknown' })
    )
    expect(api_client).not_to receive(:register_phone_number)

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('outcome_unknown') }
  end

  it 'blocks a retry when provider success could not be persisted locally' do
    allow(api_client).to receive(:register_phone_number).once.and_return('success' => true)
    allow(service).to receive(:persist_success!).and_raise(ActiveRecord::ConnectionNotEstablished, 'database unavailable')

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) do |error|
        expect(error.error_code).to eq('outcome_unknown')
        expect(error.cause).to be_a(ActiveRecord::ConnectionNotEstablished)
      end
    expect(channel.reload.provider_config.dig(described_class::CONFIG_KEY, 'status')).to eq('registering')

    expect { described_class.new(channel, api_client: api_client).perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('outcome_unknown') }
  end

  it 'does not reconcile a fresh registering state from concurrent health' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge(
        described_class::CONFIG_KEY => { 'status' => 'registering', 'attempted_at' => Time.current.iso8601 }
      )
    )

    result = service.reconcile_from_health!(pending: false, active: true, probe_started_at: 1.minute.from_now)

    expect(result).to be(false)
    expect(channel.reload.provider_config.dig(described_class::CONFIG_KEY, 'status')).to eq('registering')
  end

  it 'does not reconcile a fresh unknown outcome from stale health' do
    failed_at = Time.current
    channel.persist_provider_config_state!(
      channel.provider_config.merge(
        described_class::CONFIG_KEY => { 'status' => 'outcome_unknown', 'failed_at' => failed_at.iso8601(6) }
      )
    )

    result = service.reconcile_from_health!(pending: true, active: false, probe_started_at: failed_at + 1.minute)

    expect(result).to be(false)
    expect(channel.reload.provider_config.dig(described_class::CONFIG_KEY, 'status')).to eq('outcome_unknown')
  end

  it 'rejects a malformed PIN before calling Meta' do
    expect(api_client).not_to receive(:register_phone_number)

    expect { service.perform(pin: '12345') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('invalid_pin') }
  end

  it 'blocks automatic registration after health detects an incomplete lifecycle' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge(described_class::CONFIG_KEY => { 'status' => 'registration_incomplete' })
    )

    expect(service.automatic_retry_blocked?).to be(true)
  end

  it 'keeps a successful provider result when inbox cache invalidation fails' do
    allow(api_client).to receive(:register_phone_number).and_return('success' => true)
    allow(channel.inbox).to receive(:update_account_cache).and_raise('cache unavailable')

    expect { service.perform(pin: '654321') }.not_to raise_error
    expect(channel.reload.provider_config.dig(described_class::CONFIG_KEY, 'status')).to eq('registered')
  end

  it 'rejects a duplicate submit after a concurrent registration completed' do
    channel.persist_provider_config_state!(
      channel.provider_config.merge(described_class::CONFIG_KEY => { 'status' => 'registered' })
    )
    expect(api_client).not_to receive(:register_phone_number)

    expect { service.perform(pin: '654321') }
      .to raise_error(described_class::Error) { |error| expect(error.error_code).to eq('registration_not_required') }
  end

  it 'does not label a local pre-provider failure as an unknown Meta outcome' do
    allow(channel).to receive(:with_lock).and_raise(ActiveRecord::ConnectionNotEstablished, 'database unavailable')
    expect(api_client).not_to receive(:register_phone_number)
    expect(service).not_to receive(:persist_failure!)

    expect { service.perform(pin: '654321') }
      .to raise_error(ActiveRecord::ConnectionNotEstablished, 'database unavailable')
  end
end
