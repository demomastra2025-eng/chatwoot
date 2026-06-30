# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Meta::AdReferralRecorder do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) do
    create(
      :message,
      account: account,
      inbox: conversation.inbox,
      conversation: conversation,
      source_id: 'wamid.meta-referral-1'
    )
  end
  let(:payload) do
    {
      provider: 'whatsapp',
      attribution_type: 'click_to_whatsapp_ad',
      source: 'ad',
      source_id: '23877210000123456',
      ad_id: '23877210000123456',
      ctwa_clid: 'ctwa-click-id-1',
      headline: 'Premium consultation',
      raw_referral: { 'ctwa_clid' => 'ctwa-click-id-1' },
      received_at: '2026-06-30T10:00:00Z'
    }
  end

  it 'persists the source row and denormalized summaries for message and conversation' do
    referral = described_class.new(message: message, payload: payload).perform

    expect(referral).to be_persisted
    expect(referral.provider_message_id).to eq('wamid.meta-referral-1')
    expect(referral.ctwa_clid).to eq('ctwa-click-id-1')
    expect(message.reload.content_attributes).to include(
      'meta_ad_referral_id' => referral.id,
      'meta_referral' => a_hash_including('ctwa_clid' => 'ctwa-click-id-1')
    )
    expect(conversation.reload.additional_attributes.dig('meta_ad_referral', 'id')).to eq(referral.id)
    expect(conversation.contact.reload.additional_attributes).not_to have_key('last_meta_ad_referral')
  end

  it 'retries once when a concurrent duplicate insert wins the unique index race' do
    calls = 0
    allow(MetaAdReferral).to receive(:find_or_initialize_by).and_wrap_original do |original, *args|
      calls += 1
      referral = original.call(*args)
      allow(referral).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique) if calls == 1
      referral
    end

    referral = described_class.new(message: message, payload: payload).perform

    expect(calls).to eq(2)
    expect(referral).to be_persisted
    expect(MetaAdReferral.where(provider: 'whatsapp', inbox: message.inbox, provider_message_id: 'wamid.meta-referral-1').count).to eq(1)
  end
end
