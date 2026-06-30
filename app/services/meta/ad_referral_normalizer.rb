# frozen_string_literal: true

class Meta::AdReferralNormalizer
  class << self
    def from_whatsapp_message(message)
      message = indifferent_hash(message)
      referral = indifferent_hash(message[:referral])
      return if referral.blank?

      compact_payload(
        provider: 'whatsapp',
        attribution_type: 'click_to_whatsapp_ad',
        source: referral[:source_type].presence || 'ad',
        source_type: referral[:source_type],
        source_id: referral[:source_id],
        source_url: referral[:source_url],
        ad_id: referral[:source_id],
        ctwa_clid: referral[:ctwa_clid],
        headline: referral[:headline],
        body: referral[:body],
        media_type: referral[:media_type],
        image_url: referral[:image_url],
        video_url: referral[:video_url],
        thumbnail_url: referral[:thumbnail_url],
        received_at: timestamp_to_time(message[:timestamp])&.iso8601,
        raw_referral: stringify_hash(referral)
      )
    end

    def from_messenger_payload(messaging, provider:)
      messaging = indifferent_hash(messaging)
      message = indifferent_hash(messaging[:message])
      postback = indifferent_hash(messaging[:postback])
      referral = referral_from_messenger_payload(messaging, message, postback)
      return if referral.blank?

      ads_context = indifferent_hash(referral[:ads_context_data])
      ad_id = referral[:ad_id]
      source = referral[:source]

      compact_payload(
        provider: provider,
        attribution_type: messenger_attribution_type(provider, source),
        source: source,
        source_type: source,
        source_id: ad_id,
        source_url: referral[:referer_uri],
        ad_id: ad_id,
        ref: referral[:ref],
        referral_type: referral[:type],
        headline: ads_context[:ad_title],
        media_type: media_type_for(ads_context),
        image_url: ads_context[:photo_url],
        video_url: ads_context[:video_url],
        thumbnail_url: ads_context[:video_url],
        post_id: ads_context[:post_id],
        product_id: ads_context[:product_id],
        flow_id: ads_context[:flow_id],
        received_at: messenger_timestamp_to_time(messaging[:timestamp])&.iso8601,
        raw_referral: stringify_hash(referral)
      )
    end

    private

    def referral_from_messenger_payload(messaging, message, postback)
      referral = indifferent_hash(message[:referral]).presence ||
                 indifferent_hash(messaging[:referral]).presence ||
                 indifferent_hash(postback[:referral]).presence
      return if referral.blank?

      # Instagram docs may wrap CTD ad payloads in a nested referral object when
      # the outer referral identifies a product/shop entry point.
      nested_referral = indifferent_hash(referral[:referral])
      nested_referral.presence || referral
    end

    def messenger_attribution_type(provider, source)
      return 'click_to_direct_ad' if provider == 'instagram' && source.to_s.casecmp('ADS').zero?
      return 'click_to_messenger_ad' if provider == 'facebook' && source.to_s.casecmp('ADS').zero?

      'messaging_referral'
    end

    def media_type_for(ads_context)
      return 'video' if ads_context[:video_url].present?
      return 'image' if ads_context[:photo_url].present?
    end

    def messenger_timestamp_to_time(timestamp)
      return if timestamp.blank?

      numeric_timestamp = timestamp.to_f
      numeric_timestamp /= 1000 if numeric_timestamp > 10_000_000_000
      Time.zone.at(numeric_timestamp)
    rescue ArgumentError, TypeError
      nil
    end

    def timestamp_to_time(timestamp)
      return if timestamp.blank?

      Time.zone.at(timestamp.to_f)
    rescue ArgumentError, TypeError
      nil
    end

    def indifferent_hash(value)
      value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
    end

    def stringify_hash(value)
      indifferent_hash(value).to_h.deep_stringify_keys
    end

    def compact_payload(payload)
      payload.compact_blank
    end
  end
end
