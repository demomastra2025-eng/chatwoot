# frozen_string_literal: true

class Meta::AdReferralRecorder
  SUMMARY_ATTRIBUTE_KEY = 'meta_ad_referral'

  attr_reader :message, :payload

  def initialize(message:, payload:)
    @message = message
    @payload = payload.to_h.with_indifferent_access
  end

  def perform
    return if message.blank? || payload.blank?
    return if payload[:provider].blank?

    referral = upsert_referral!
    summary = referral.summary
    persist_message_summary!(summary)
    persist_additional_attribute!(message.conversation, SUMMARY_ATTRIBUTE_KEY, summary)
    referral
  end

  private

  def upsert_referral!
    MetaAdReferral.find_or_initialize_by(unique_attributes).tap do |referral|
      referral.assign_attributes(record_attributes)
      referral.save!
    end
  rescue ActiveRecord::RecordNotUnique
    @upsert_retry_count ||= 0
    raise if @upsert_retry_count.positive?

    @upsert_retry_count += 1
    retry
  end

  def unique_attributes
    {
      provider: payload[:provider],
      inbox_id: message.inbox_id,
      provider_message_id: provider_message_id
    }
  end

  def record_attributes
    {
      account_id: message.account_id,
      inbox_id: message.inbox_id,
      contact_id: message.conversation&.contact_id || message.sender_id,
      conversation_id: message.conversation_id,
      communication_thread_id: communication_thread&.id,
      message_id: message.id,
      provider: payload[:provider],
      provider_message_id: provider_message_id,
      attribution_type: payload[:attribution_type],
      source: payload[:source],
      source_type: payload[:source_type],
      source_id: payload[:source_id],
      source_url: payload[:source_url],
      ad_id: payload[:ad_id],
      ctwa_clid: payload[:ctwa_clid],
      ref: payload[:ref],
      referral_type: payload[:referral_type],
      headline: payload[:headline],
      body: payload[:body],
      media_type: payload[:media_type],
      image_url: payload[:image_url],
      video_url: payload[:video_url],
      thumbnail_url: payload[:thumbnail_url],
      post_id: payload[:post_id],
      product_id: payload[:product_id],
      flow_id: payload[:flow_id],
      raw_referral: payload[:raw_referral].presence || {},
      received_at: received_at
    }
  end

  def provider_message_id
    message.source_id.presence || message.id.to_s
  end

  def received_at
    parsed_time = Time.zone.parse(payload[:received_at].to_s) if payload[:received_at].present?
    parsed_time || message.created_at || Time.current
  rescue ArgumentError, TypeError
    message.created_at || Time.current
  end

  def communication_thread
    return @communication_thread if defined?(@communication_thread)

    @communication_thread = begin
      conversation = message.conversation
      if conversation&.account&.feature_enabled?('communication_threads')
        conversation.communication_thread || conversation.refresh_communication_thread!
      else
        conversation&.communication_thread
      end
    rescue StandardError => e
      Rails.logger.warn("[MetaAdReferral] communication thread link failed: #{e.class}: #{e.message}")
      nil
    end
  end

  def persist_message_summary!(summary)
    attributes = message.content_attributes.to_h.with_indifferent_access
    attributes[:meta_ad_referral_id] = summary[:id]
    attributes[:meta_referral] = payload.merge(meta_ad_referral_id: summary[:id]).compact_blank
    message.content_attributes = attributes
    message.update_columns(content_attributes: attributes, updated_at: Time.current)
  end

  def persist_additional_attribute!(record, key, summary)
    return if record.blank?
    return unless record.respond_to?(:additional_attributes)

    attributes = record.additional_attributes.to_h.deep_dup
    attributes[key] = summary.deep_stringify_keys
    record.update_columns(additional_attributes: attributes, updated_at: Time.current)
  end
end
