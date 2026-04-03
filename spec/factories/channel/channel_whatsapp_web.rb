FactoryBot.define do
  factory :channel_whatsapp_web, class: 'Channel::WhatsappWeb' do
    account
    sequence(:phone_number) { |n| "+1555123#{format('%04d', n)}" }
    provider { 'evolution' }
    provider_config { {} }
    lifecycle_state { 'creating' }
    connection_state { 'close' }
    qr_code { {} }
    conversation_pending { false }
    history_lookback_days { 0 }
    ignore_jids { [] }
    sign_messages { false }
    sign_delimiter { '\\n' }
    import_contacts { true }
    import_messages { true }
    sync_labels { true }

    transient do
      skip_provisioning { true }
    end

    before(:create) do |channel, evaluator|
      channel.define_singleton_method(:enqueue_provisioning) { nil } if evaluator.skip_provisioning
    end

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
