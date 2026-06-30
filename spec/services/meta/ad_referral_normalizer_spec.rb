# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Meta::AdReferralNormalizer do
  describe '.from_whatsapp_message' do
    it 'normalizes WhatsApp Cloud CTWA referral fields without hashing ctwa_clid' do
      message = {
        id: 'wamid.1',
        timestamp: '1770407829',
        referral: {
          source_url: 'https://fb.me/ad',
          source_type: 'ad',
          source_id: '23877210000123456',
          headline: 'Ad headline',
          body: 'Ad body',
          media_type: 'image',
          image_url: 'https://lookaside.fbsbx.com/image.jpg',
          thumbnail_url: 'https://lookaside.fbsbx.com/thumb.jpg',
          ctwa_clid: 'plain-ctwa-click-id'
        }
      }.with_indifferent_access

      payload = described_class.from_whatsapp_message(message)

      expect(payload).to include(
        provider: 'whatsapp',
        attribution_type: 'click_to_whatsapp_ad',
        source: 'ad',
        source_id: '23877210000123456',
        ad_id: '23877210000123456',
        ctwa_clid: 'plain-ctwa-click-id',
        headline: 'Ad headline',
        image_url: 'https://lookaside.fbsbx.com/image.jpg'
      )
      expect(payload[:raw_referral]).to include('ctwa_clid' => 'plain-ctwa-click-id')
    end
  end

  describe '.from_messenger_payload' do
    it 'returns nil for regular Messenger messages without referral metadata' do
      payload = described_class.from_messenger_payload(
        { message: { mid: 'mid.regular', text: 'Hi' } },
        provider: 'facebook'
      )

      expect(payload).to be_nil
    end

    it 'normalizes Facebook Messenger ads referral fields' do
      messaging = {
        timestamp: 1_770_407_829_000,
        sender: { id: 'psid-1' },
        recipient: { id: 'page-1' },
        message: { mid: 'mid.1', text: 'Hi' },
        referral: {
          ref: 'spring_campaign',
          ad_id: '1200123456789',
          source: 'ADS',
          type: 'OPEN_THREAD',
          ads_context_data: {
            ad_title: 'Messenger ad',
            photo_url: 'https://fbcdn.example/ad.jpg',
            post_id: 'post-1',
            product_id: 'product-1',
            flow_id: 'flow-1'
          }
        }
      }.with_indifferent_access

      payload = described_class.from_messenger_payload(messaging, provider: 'facebook')

      expect(payload).to include(
        provider: 'facebook',
        attribution_type: 'click_to_messenger_ad',
        source: 'ADS',
        source_id: '1200123456789',
        ad_id: '1200123456789',
        ref: 'spring_campaign',
        referral_type: 'OPEN_THREAD',
        headline: 'Messenger ad',
        media_type: 'image',
        image_url: 'https://fbcdn.example/ad.jpg',
        post_id: 'post-1',
        product_id: 'product-1',
        flow_id: 'flow-1'
      )
    end

    it 'normalizes Instagram Click-to-Direct ads embedded in message.referral' do
      messaging = {
        timestamp: 1_770_407_829_000,
        message: {
          mid: 'mid.ig.1',
          text: 'Hi',
          referral: {
            ad_id: 'ig-ad-1',
            source: 'ADS',
            type: 'OPEN_THREAD',
            ads_context_data: {
              ad_title: 'Instagram ad',
              video_url: 'https://fbcdn.example/video-thumb.jpg'
            }
          }
        }
      }.with_indifferent_access

      payload = described_class.from_messenger_payload(messaging, provider: 'instagram')

      expect(payload).to include(
        provider: 'instagram',
        attribution_type: 'click_to_direct_ad',
        ad_id: 'ig-ad-1',
        media_type: 'video',
        video_url: 'https://fbcdn.example/video-thumb.jpg'
      )
    end
  end
end
