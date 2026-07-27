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

    trait :sipuni do
      provider { 'sipuni' }
      provider_config do
        {
          number_ref: SecureRandom.uuid,
          provider_kind: 'sipuni',
          routing_mode: 'operator',
          operator_agent_aor: "sip:agent-#{SecureRandom.hex(4)}@example.test"
        }
      end

      before(:create) do |channel_voice|
        config = channel_voice.provider_config.to_h.with_indifferent_access
        provider_kind = config[:provider_kind].presence || channel_voice.provider
        next unless provider_kind.to_s.in?(%w[asterisk_analog sipuni binotel beeline])
        next if config[:provider_connection_id].present?

        connection = create(
          :telephony_provider_connection,
          account: channel_voice.account,
          provider_kind: provider_kind
        )
        config[:provider_connection_id] = connection.id
        config[:number_ref] = SecureRandom.uuid if config[:number_ref].blank?
        channel_voice.provider_config = config.to_h
      end

      after(:create) do |channel_voice|
        Telephony::NumberBinding.sync_from_voice_channel!(channel_voice)
      end
    end
  end
end
