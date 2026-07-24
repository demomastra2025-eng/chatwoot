require 'rails_helper'

RSpec.describe Whatsapp::ChannelIdentityUpdateGuard do
  subject(:guard) { described_class.new(channel) }

  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false,
      phone_number: '+15550001111',
      provider_config: {
        'api_key' => 'old-token',
        'business_account_id' => 'waba-1',
        'phone_number_id' => 'phone-1',
        'source' => 'embedded_signup'
      }
    )
  end

  it 'allows non-identity provider configuration updates' do
    expect { guard.validate!(provider_config: channel.provider_config.merge('api_key' => 'new-token')) }.not_to raise_error
  end

  it 'rejects a WABA identity change' do
    params = { provider_config: channel.provider_config.merge('business_account_id' => 'waba-2') }

    expect { guard.validate!(params) }.to raise_error(ActiveRecord::RecordInvalid, /business_account_id/)
  end

  it 'rejects a callback route phone change' do
    expect { guard.validate!(phone_number: '+155****2222') }
      .to raise_error(ActiveRecord::RecordInvalid, /phone_number/)
  end

  it 'rejects changing a Cloud channel to the unsigned default provider' do
    expect { guard.validate!(provider: 'default') }
      .to raise_error(ActiveRecord::RecordInvalid, /provider/)
  end

  it 'rejects changing a default channel to the Cloud provider' do
    channel.update!(provider: 'default')

    expect { guard.validate!(provider: 'whatsapp_cloud') }
      .to raise_error(ActiveRecord::RecordInvalid, /provider/)
  end
end
