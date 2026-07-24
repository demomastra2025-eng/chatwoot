require 'rails_helper'

RSpec.describe Whatsapp::AccountUpdateChannelResolver do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:waba_id) { channel.provider_config['business_account_id'] }

  it 'returns all matching channels when the WABA belongs to one account' do
    second_channel = create(
      :channel_whatsapp,
      account: channel.account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    second_channel.update!(provider_config: second_channel.provider_config.merge('business_account_id' => waba_id))

    result = described_class.new(waba_ids: [waba_id]).resolve

    expect(result).to contain_exactly(channel, second_channel)
  end

  it 'fails closed when the same WABA is configured in multiple accounts' do
    other_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    other_channel.update!(provider_config: other_channel.provider_config.merge('business_account_id' => waba_id))
    allow(Rails.logger).to receive(:error)

    result = described_class.new(waba_ids: [waba_id]).resolve

    expect(result).to be_empty
    expect(Rails.logger).to have_received(:error)
      .with('[WHATSAPP ACCOUNT UPDATE] refused event because WABA ownership spans multiple accounts')
  end

  it 'excludes channels owned by suspended accounts' do
    channel.account.suspended!

    result = described_class.new(waba_ids: [waba_id]).resolve

    expect(result).to be_empty
  end

  it 'excludes channels whose inbox is pending deletion' do
    channel.inbox.update!(deleting_at: Time.current)

    result = described_class.new(waba_ids: [waba_id]).resolve

    expect(result).to be_empty
  end

  it 'does not treat a suspended owner as an active cross-account ambiguity' do
    suspended_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    suspended_channel.update!(provider_config: suspended_channel.provider_config.merge('business_account_id' => waba_id))
    suspended_channel.account.suspended!

    result = described_class.new(waba_ids: [waba_id]).resolve

    expect(result).to contain_exactly(channel)
  end

  it 'fails closed while a cross-account WABA owner is pending deletion' do
    pending_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    pending_channel.update!(provider_config: pending_channel.provider_config.merge('business_account_id' => waba_id))
    pending_channel.inbox.update!(deleting_at: Time.current)

    expect(described_class.new(waba_ids: [waba_id]).resolve).to be_empty
  end
end
