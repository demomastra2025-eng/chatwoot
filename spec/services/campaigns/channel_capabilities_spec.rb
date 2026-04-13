require 'rails_helper'

RSpec.describe Campaigns::ChannelCapabilities do
  describe '.for' do
    let(:account) { create(:account) }

    before do
      stub_request(:post, /graph.facebook.com/).to_return(status: 200, body: '{}', headers: {})
    end

    it 'returns ready outbound capabilities for sms inboxes' do
      inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:planned_rollout_tier]).to eq(1)
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
    end

    it 'marks whatsapp twilio inboxes as template-aware' do
      inbox = create(:inbox, account: account, channel: create(:channel_twilio_sms, :whatsapp, account: account))

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:requires_template_for_outside_window]).to be(true)
    end

    it 'blocks whatsapp capabilities when the feature is disabled' do
      channel = create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false)
      account.disable_features!(:whatsapp_campaign)

      capabilities = described_class.for(inbox: channel.inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(false)
      expect(capabilities[:delivery_readiness]).to eq('unsupported')
      expect(capabilities[:notes]).to include('WhatsApp campaigns feature is not enabled for this account.')
    end

    it 'keeps website inboxes on a separate campaign surface' do
      inbox = create(:inbox, account: account)

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(false)
      expect(capabilities[:campaign_surface]).to eq('website_trigger')
      expect(capabilities[:delivery_readiness]).to eq('separate_surface')
    end

    it 'marks email as ready in the shared outbound runner' do
      channel = create(:channel_email, account: account)
      inbox = channel.inbox

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:supports_subject]).to be(true)
      expect(capabilities[:supports_html]).to be(true)
    end

    it 'marks line as ready in the shared outbound runner' do
      channel = create(:channel_line, account: account, inbox: nil)
      inbox = create(:inbox, account: account, channel: channel)

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:requires_existing_target]).to be(true)
      expect(capabilities[:supports_media]).to be(true)
      expect(capabilities[:supports_buttons]).to be(true)
    end

    it 'marks facebook as reply-window gated and ready in the shared outbound runner' do
      channel = create(:channel_facebook_page, account: account, inbox: nil)
      inbox = create(:inbox, account: account, channel: channel)

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:requires_existing_target]).to be(true)
      expect(capabilities[:requires_open_reply_window]).to be(true)
    end

    it 'marks instagram as reply-window gated and ready in the shared outbound runner' do
      channel = create(:channel_instagram, account: account)
      inbox = channel.inbox

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:requires_existing_target]).to be(true)
      expect(capabilities[:requires_open_reply_window]).to be(true)
    end

    it 'marks telegram bot as ready in the shared outbound runner' do
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:requires_existing_target]).to be(true)
      expect(capabilities[:supports_buttons]).to be(true)
    end

    it 'marks tiktok as reply-window gated and ready in the shared outbound runner' do
      channel = create(:channel_tiktok, account: account)
      inbox = channel.inbox

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:requires_existing_target]).to be(true)
      expect(capabilities[:requires_open_reply_window]).to be(true)
    end

    it 'marks twitter as direct-message outbound only in the shared runner' do
      channel = create(:channel_twitter_profile, account: account)
      inbox = create(:inbox, account: account, channel: channel)

      capabilities = described_class.for(inbox: inbox)

      expect(capabilities[:supports_outbound_campaigns]).to be(true)
      expect(capabilities[:delivery_readiness]).to eq('ready')
      expect(capabilities[:implemented_in_current_campaigns]).to be(true)
      expect(capabilities[:requires_existing_target]).to be(true)
      expect(capabilities[:notes]).to include('Outbound campaigns use direct messages only and require an existing Twitter DM thread. Tweet reply conversations stay outside this surface.')
    end
  end
end
