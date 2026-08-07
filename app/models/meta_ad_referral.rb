# frozen_string_literal: true

# == Schema Information
#
# Table name: meta_ad_referrals
#
#  id                      :bigint           not null, primary key
#  attribution_type        :string
#  body                    :text
#  ctwa_clid               :string
#  headline                :string
#  image_url               :text
#  media_type              :string
#  provider                :string           not null
#  raw_referral            :jsonb            not null
#  received_at             :datetime         not null
#  ref                     :string
#  referral_type           :string
#  source                  :string
#  source_type             :string
#  source_url              :text
#  thumbnail_url           :text
#  video_url               :text
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  ad_id                   :string
#  communication_thread_id :bigint
#  contact_id              :bigint
#  conversation_id         :bigint
#  flow_id                 :string
#  inbox_id                :bigint           not null
#  message_id              :bigint
#  post_id                 :string
#  product_id              :string
#  provider_message_id     :string           not null
#  source_id               :string
#
# Indexes
#
#  idx_meta_ad_referrals_account_ad                    (account_id,ad_id) WHERE (ad_id IS NOT NULL)
#  idx_meta_ad_referrals_account_conversation          (account_id,conversation_id)
#  idx_meta_ad_referrals_account_ctwa                  (account_id,ctwa_clid) WHERE (ctwa_clid IS NOT NULL)
#  idx_meta_ad_referrals_account_source                (account_id,source_id) WHERE (source_id IS NOT NULL)
#  idx_meta_ad_referrals_account_thread                (account_id,communication_thread_id)
#  idx_meta_ad_referrals_provider_message              (provider,inbox_id,provider_message_id) UNIQUE
#  index_meta_ad_referrals_on_account_id               (account_id)
#  index_meta_ad_referrals_on_communication_thread_id  (communication_thread_id)
#  index_meta_ad_referrals_on_contact_id               (contact_id)
#  index_meta_ad_referrals_on_conversation_id          (conversation_id)
#  index_meta_ad_referrals_on_inbox_id                 (inbox_id)
#  index_meta_ad_referrals_on_message_id               (message_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (communication_thread_id => communication_threads.id) ON DELETE => nullify
#  fk_rails_...  (contact_id => contacts.id) ON DELETE => nullify
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => nullify
#  fk_rails_...  (inbox_id => inboxes.id) ON DELETE => cascade
#  fk_rails_...  (message_id => messages.id) ON DELETE => nullify
#
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
