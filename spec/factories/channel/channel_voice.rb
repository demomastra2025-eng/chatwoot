# frozen_string_literal: true

FactoryBot.define do
  factory :channel_voice, class: 'Channel::Voice' do
    sequence(:phone_number) { |n| "+155512345#{n.to_s.rjust(2, '0')}" }
    provider { 'twilio' }
    provider_config do
      {
        account_sid: "AC#{SecureRandom.hex(16)}",
        auth_token: SecureRandom.hex(16),
        api_key_sid: SecureRandom.hex(8),
        api_key_secret: SecureRandom.hex(16),
        twiml_app_sid: "AP#{SecureRandom.hex(16)}"
      }
    end
    account

    after(:create) do |channel_voice|
      create(:inbox, channel: channel_voice, account: channel_voice.account)
    end

    trait :fonoster do
      provider { 'fonoster' }
      provider_config do
        {
          number_ref: SecureRandom.uuid,
          app_ref: SecureRandom.uuid,
          trunk_ref: SecureRandom.uuid,
          routing_mode: 'operator',
          operator_agent_aor: "sip:agent-#{SecureRandom.hex(4)}@example.test"
        }
      end

      after(:create) do |channel_voice|
        Telephony::NumberBinding.sync_from_voice_channel!(channel_voice)
      end
    end

    trait :sipuni do
      provider { 'sipuni' }
      provider_config do
        {
          account_number: rand(100_000..999_999).to_s,
          integration_secret: SecureRandom.hex(16),
          webhook_token: SecureRandom.hex(24),
          audio_mode: 'external_softphone',
          default_internal_number: '100'
        }
      end
    end
  end
end
