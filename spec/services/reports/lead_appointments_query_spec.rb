require 'rails_helper'

RSpec.describe Reports::LeadAppointmentsQuery do
  let(:account) { create(:account, reporting_timezone: 'UTC') }
  let(:inbox) { create(:inbox, account: account) }
  let(:now) { Time.utc(2026, 10, 12, 12) }
  let(:first_at) { Time.utc(2026, 10, 10, 8) }
  let(:range) { Reports::DateRange.new(account: account, params: { from_date: '2026-10-10', to_date: '2026-10-10' }, now: now) }

  around { |example| travel_to(now) { example.run } }

  def incoming(contact, at: first_at, **attributes)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact, created_at: at, **attributes)
  end

  def provider_visit(contact, patient: nil, **attributes)
    create(:scheduling_appointment, account: account, contact: contact, patient_contact: patient, created_at: first_at + 1.hour,
                                    source: 'medelement', custom_attributes: { medelement_reception_code: SecureRandom.uuid }, **attributes)
  end

  def report
    described_class.new(account: account, date_range: range, now: now).perform
  end

  it 'counts a mother with two clinical patients as one lead and two confirmed provider appointments' do
    mother = create(:contact, account: account)
    incoming(mother)
    provider_visit(mother, patient: create(:contact, account: account))
    provider_visit(mother, patient: create(:contact, account: account), status: 'completed', attendance_confirmed_at: now)

    expect(report).to include(leads_count: 1, booked_leads_count: 1, attended_leads_count: 1, appointments_count: 2,
                             provider_booked_appointments_count: 2, attended_appointments_count: 1,
                             booking_conversion_percent: 100.0, attendance_conversion_percent: 100.0)
  end

  it 'excludes a repeat contact first seen earlier even across another inbox conversation' do
    repeat = create(:contact, account: account)
    incoming(repeat, at: first_at - 2.days)
    incoming(repeat)
    provider_visit(repeat)
    fresh = create(:contact, account: account)
    incoming(fresh)

    expect(report).to include(leads_count: 1, booked_leads_count: 0, appointments_count: 0, repeat_contacts_count: 1)
  end

  it 'ignores outgoing messages and notes when determining the first inbound cohort' do
    contact = create(:contact, account: account)
    incoming(contact, at: first_at - 1.day, message_type: 'outgoing', sender: create(:user, account: account))
    incoming(contact, at: first_at - 1.day, private: true)
    incoming(contact)

    expect(report[:leads_count]).to eq(1)
  end

  it 'does not count a local plan or provider inactivity as actual provider booking and attendance' do
    contact = create(:contact, account: account)
    incoming(contact)
    create(:scheduling_appointment, account: account, contact: contact, created_at: first_at + 1.hour)
    provider_visit(contact, status: 'completed', custom_attributes: { medelement_reception_code: 'inactive', provider_status_audit: { reason: 'provider_inactive' } })
    provider_visit(contact, status: 'cancelled')

    expect(report).to include(booked_leads_count: 1, attended_leads_count: 0, appointments_count: 3,
                             provider_booked_appointments_count: 2, unknown_attendance_appointments_count: 1,
                             cancelled_or_no_show_appointments_count: 1)
  end

  it 'preserves first-message origin attribution and separates deal results from lead conversion' do
    contact = create(:contact, account: account)
    first_message = incoming(contact)
    create(:meta_ad_referral, account: account, inbox: inbox, contact: contact, conversation: first_message.conversation,
                              message: first_message, source: 'instagram', attribution_type: 'click_to_whatsapp_ad')
    pipeline = create(:crm_pipeline, account: account)
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won', default: false)
    won = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, created_at: first_at + 1.hour, closed_at: now)
    create(:crm_deal_contact, account: account, deal: won, contact: contact, primary: true)

    result = report
    expect(result).to include(leads_count: 1, booked_leads_count: 0, deals_count: 1, won_deals_count: 1)
    expect(result[:attribution_breakdown].first).to include(inbox_id: inbox.id, source: 'instagram', leads_count: 1)
  end

  it 'keeps attribution limited to the communication contact and labels missing contact data' do
    contact = create(:contact, account: account)
    clinical = create(:contact, account: account)
    incoming(contact)
    provider_visit(clinical)
    create(:scheduling_appointment, account: account, contact: nil, client_name: 'Unlinked', client_phone: nil, client_identifier: nil, created_at: first_at + 1.hour)
    other = create(:account)
    create(:message, account: other, created_at: first_at)
    create(:scheduling_appointment, account: other, source: 'medelement', custom_attributes: { medelement_reception_code: 'other' })

    expect(report).to include(leads_count: 1, booked_leads_count: 0, appointments_count: 0, appointments_without_contact_count: 1)
    expect(report[:attribution_breakdown].first[:source]).to eq('unknown')
  end
end
