# frozen_string_literal: true

class MetaAdReferral < ApplicationRecord
  belongs_to :account
  belongs_to :inbox
  belongs_to :contact, optional: true
  belongs_to :conversation, optional: true
  belongs_to :communication_thread, optional: true
  belongs_to :message, optional: true

  validates :provider, :provider_message_id, :received_at, presence: true
  validates :provider_message_id, uniqueness: { scope: [:provider, :inbox_id] }

  def summary
    {
      id: id,
      provider: provider,
      attribution_type: attribution_type,
      source: source,
      source_type: source_type,
      source_id: source_id,
      source_url: source_url,
      ad_id: ad_id,
      ctwa_clid: ctwa_clid,
      ref: ref,
      referral_type: referral_type,
      headline: headline,
      body: body,
      media_type: media_type,
      image_url: image_url,
      video_url: video_url,
      thumbnail_url: thumbnail_url,
      post_id: post_id,
      product_id: product_id,
      flow_id: flow_id,
      received_at: received_at&.iso8601,
      conversation_id: conversation&.display_id,
      communication_thread_id: communication_thread&.display_id,
      message_id: message_id
    }.compact_blank
  end
end
