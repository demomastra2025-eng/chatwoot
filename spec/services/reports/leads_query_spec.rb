# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::LeadsQuery do
  let(:account) { create(:account, reporting_timezone: 'Europe/Berlin') }
  let(:contact) { create(:contact, account: account) }

  def report_params
    { from_date: '2026-03-29', to_date: '2026-03-29' }
  end

  it 'keeps referral events, explicit ad referrals, and unique contacts separate' do
    inbox = create(:inbox, account: account)
    received_at = Time.iso8601('2026-03-28T23:30:00Z')
    2.times do |index|
      create(
        :meta_ad_referral,
        account: account,
        inbox: inbox,
        contact: contact,
        provider: 'whatsapp',
        provider_message_id: "whatsapp-message-#{index}",
        attribution_type: 'click_to_whatsapp_ad',
        source_type: 'ad',
        ad_id: 'campaign-42',
        ctwa_clid: "click-#{index}",
        received_at: received_at + index.minutes
      )
    end
    create(
      :meta_ad_referral,
      account: account,
      inbox: inbox,
      contact: contact,
      provider: 'facebook',
      provider_message_id: 'messenger-organic-message',
      attribution_type: 'messaging_referral',
      source_type: 'NON_AD_REFERRAL',
      referral_type: 'OPEN_THREAD',
      received_at: received_at + 2.minutes
    )
    create(
      :meta_ad_referral,
      account: create(:account),
      provider_message_id: 'other-account-message',
      received_at: received_at
    )

    referrals = described_class.new(account: account, params: report_params).perform.fetch(:referrals)

    expect(referrals).to include(
      event_count: 3,
      unique_contact_count: 1,
      events_without_contact_count: 0,
      explicit_paid_ad_event_count: 2,
      other_or_unknown_event_count: 1,
      unique_ctwa_click_id_count: 2
    )
    expect(referrals.fetch(:attribution_breakdown)).to include(
      include(provider: 'facebook', attribution_type: 'messaging_referral', source_type: 'NON_AD_REFERRAL', referral_type: 'OPEN_THREAD', event_count: 1)
    )
  end

  it 'reports LeadSubmission event, source, processing, and UTM counts within the account date range' do
    api_form = create(:lead_form, account: account, source_kind: 'api')
    widget_form = create(:lead_form, account: account, source_kind: 'widget')
    created_at = Time.iso8601('2026-03-28T23:30:00Z')
    create(
      :lead_submission,
      account: account,
      lead_form: api_form,
      contact: contact,
      source_kind: 'api',
      status: 'processed',
      created_at: created_at,
      processed_at: created_at + 60.seconds,
      utm: { 'utm_source' => 'newsletter', 'utm_campaign' => 'spring' }
    )
    create(
      :lead_submission,
      account: account,
      lead_form: widget_form,
      contact: nil,
      source_kind: 'widget',
      status: 'failed',
      created_at: created_at + 2.minutes,
      processed_at: nil,
      utm: {}
    )
    foreign_form = create(:lead_form, account: create(:account), source_kind: 'api')
    create(
      :lead_submission,
      account: foreign_form.account,
      lead_form: foreign_form,
      source_kind: 'api',
      status: 'processed',
      created_at: created_at,
      processed_at: created_at + 30.seconds
    )

    report = described_class.new(account: account, params: report_params).perform
    submissions = report.fetch(:form_submissions)

    expect(submissions).to include(
      event_count: 2,
      unique_contact_count: 1,
      events_without_contact_count: 1
    )
    expect(submissions.fetch(:source_status_breakdown)).to contain_exactly(
      { source_kind: 'api', status: 'processed', event_count: 1 },
      { source_kind: 'widget', status: 'failed', event_count: 1 }
    )
    expect(submissions.fetch(:utm_source_breakdown)).to include(
      { value: 'newsletter', event_count: 1 },
      { value: 'unknown', event_count: 1 }
    )
    expect(submissions.fetch(:utm_campaign_breakdown)).to include(
      { value: 'spring', event_count: 1 },
      { value: 'unknown', event_count: 1 }
    )
    expect(report.fetch(:processing)).to include(
      submissions_processed_in_selected_period: 1,
      selected_submissions_with_processed_at: 1,
      average_processing_seconds: 60.0
    )
  end
end
