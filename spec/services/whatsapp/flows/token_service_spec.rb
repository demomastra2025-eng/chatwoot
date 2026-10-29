require 'rails_helper'

RSpec.describe Whatsapp::Flows::TokenService do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end

  describe 'endpoint token generation and resolution' do
    it 'resolves the exact WhatsApp Cloud channel for a valid endpoint token' do
      secret = described_class.generate_endpoint_secret
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => { 'endpoint_secret' => secret }
        )
      )

      endpoint_token = described_class.build_endpoint_token(channel)
      expect(endpoint_token).to eq("ch_#{channel.id}_#{secret}")
      expect(described_class.resolve_channel_by_endpoint_token(endpoint_token)).to eq(channel)
    end

    it 'returns nil when secret does not match or token format is invalid' do
      secret = described_class.generate_endpoint_secret
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => { 'endpoint_secret' => secret }
        )
      )

      wrong_secret = described_class.generate_endpoint_secret
      expect(described_class.resolve_channel_by_endpoint_token("ch_#{channel.id}_#{wrong_secret}")).to be_nil
      expect(described_class.resolve_channel_by_endpoint_token('invalid-token')).to be_nil
    end
  end

  describe '.generate_flow_token and .verify_flow_token' do
    it 'signs and verifies flow_token claims scoped to channel and account' do
      token = described_class.generate_flow_token(
        channel: channel,
        kind: 'booking',
        conversation_id: 42,
        contact_id: 99,
        locale: 'kk',
        metadata: { service_id: '7' }
      )

      expect(token).to start_with('olf1.')
      result = described_class.verify_flow_token(token, channel: channel)

      expect(result[:valid]).to be(true)
      expect(result[:preview]).to be(false)
      expect(result[:payload]).to include(
        channel_id: channel.id,
        account_id: account.id,
        kind: 'booking',
        conversation_id: 42,
        contact_id: 99,
        locale: 'kk'
      )
      expect(result.dig(:payload, :metadata, 'service_id')).to eq('7')
    end

    it 'rejects a token verified against a different channel' do
      other_channel = create(
        :channel_whatsapp,
        account: account,
        phone_number: '+77015559988',
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      token = described_class.generate_flow_token(channel: channel, contact_id: 10)

      result = described_class.verify_flow_token(token, channel: other_channel)
      expect(result).to include(valid: false, preview: false, reason: :channel_mismatch)
    end

    it 'rejects tampered signatures and expired tokens' do
      token = described_class.generate_flow_token(channel: channel, contact_id: 10)
      tampered = "#{token[0..-3]}zz"

      expect(described_class.verify_flow_token(tampered, channel: channel))
        .to include(valid: false, preview: false, reason: :invalid_signature)

      expired = described_class.generate_flow_token(channel: channel, ttl: -1.minute)
      expect(described_class.verify_flow_token(expired, channel: channel))
        .to include(valid: false, preview: false, reason: :expired_token)
    end

    it 'marks blank, unused, and Meta Flows builder preview tokens as preview=true, valid=false' do
      ['', 'unused', 'flows-builder-12345', 'preview_abc'].each do |preview_token|
        result = described_class.verify_flow_token(preview_token, channel: channel)
        expect(result).to include(valid: false, preview: true, reason: :unsigned_or_preview)
      end
    end
  end

  describe '.generate_booking_grant and .verify_booking_grant' do
    it 'signs and verifies slot-bound booking grants and rejects tampering or expiry' do
      starts_at = 2.days.from_now.change(sec: 0)
      grant = described_class.generate_booking_grant(
        channel: channel,
        conversation_id: 11,
        contact_id: 22,
        resource_id: 7,
        service_id: 3,
        starts_at: starts_at,
        duration_min: 45,
        cabinet_code: 'cab-7'
      )

      expect(grant).to start_with('olfg1.')
      verified = described_class.verify_booking_grant(grant, channel: channel)
      expect(verified[:valid]).to be(true)
      expect(verified[:payload]).to include(
        channel_id: channel.id,
        account_id: account.id,
        conversation_id: 11,
        contact_id: 22,
        resource_id: 7,
        service_id: 3,
        duration_min: 45,
        cabinet_code: 'cab-7'
      )

      expect(described_class.verify_booking_grant("#{grant[0..-3]}zz", channel: channel))
        .to include(valid: false, reason: :invalid_signature)

      expired = described_class.generate_booking_grant(
        channel: channel, resource_id: 7, starts_at: starts_at, duration_min: 30, ttl: -1.minute
      )
      expect(described_class.verify_booking_grant(expired, channel: channel))
        .to include(valid: false, reason: :expired_grant)
    end
  end
end
