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

  it 'preserves local-day and observation boundaries with microsecond precision' do
    account.update!(reporting_timezone: 'Asia/Almaty')
    microsecond = Rational(1, 1_000_000)
    observed_at = now.change(usec: 123_456).in_time_zone('Asia/Almaty')
    incoming(create(:contact, account: account), at: range.from_at - microsecond)
    incoming(create(:contact, account: account), at: range.from_at)
    last_contact = create(:contact, account: account)
    last_at = range.until_at - microsecond
    incoming(last_contact, at: last_at)
    incoming(create(:contact, account: account), at: range.until_at)
    repeat = create(:contact, account: account)
    incoming(repeat, at: range.from_at - microsecond)
    incoming(repeat, at: range.from_at)
    provider_visit(last_contact, created_at: last_at - microsecond)
    provider_visit(last_contact, created_at: last_at)
    provider_visit(last_contact, created_at: observed_at)
    provider_visit(last_contact, created_at: observed_at + microsecond)

    result = described_class.new(account: account, date_range: range, now: observed_at).perform

    expect(result).to include(leads_count: 2, repeat_contacts_count: 1, booked_leads_count: 1, appointments_count: 2,
                             provider_booked_appointments_count: 2)
  end

  it 'ignores outgoing messages and notes when determining the first inbound cohort' do
    contact = create(:contact, account: account)
    incoming(contact, at: first_at - 1.day, message_type: 'outgoing', sender: create(:user, account: account))
    incoming(contact, at: first_at - 1.day, private: true)
    incoming(contact)

    expect(report[:leads_count]).to eq(1)
  end

  it 'counts completed provider appointments as attended while excluding unbooked local plans' do
    contact = create(:contact, account: account)
    incoming(contact)
    create(:scheduling_appointment, account: account, contact: contact, created_at: first_at + 1.hour)
    provider_visit(contact, status: 'completed', custom_attributes: { medelement_reception_code: 'inactive', provider_status_audit: { reason: 'provider_inactive' } })
    provider_visit(contact, status: 'cancelled')

    expect(report).to include(booked_leads_count: 1, attended_leads_count: 1, appointments_count: 3,
                             provider_booked_appointments_count: 2, attended_appointments_count: 1,
                             unknown_attendance_appointments_count: 0,
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

  it 'splits cancelled/removed appointments into rescheduled, early_cancelled, and true_no_show, and computes net_attendance_rate, KZT finance, full funnel, and WhatsApp touches' do
    contact = create(:contact, account: account)
    repeat_contact = create(:contact, account: account)
    incoming(repeat_contact, at: first_at - 3.days)
    incoming(repeat_contact, at: first_at + 5.minutes)
    incoming(contact, at: first_at)

    service = create(:scheduling_service, account: account, name: 'Приём терапевта', base_price: 12_000)

    # 1. Completed appointment (15,000 KZT)
    completed_apt = provider_visit(
      contact,
      service: service,
      service_amount: 15_000,
      starts_at: first_at + 2.hours,
      ends_at: first_at + 150.minutes,
      status: 'completed',
      attendance_confirmed_at: now
    )

    # 2. Rescheduled appointment (cancelled, but same contact has completed_apt within ±7 days; 15,000 KZT saved)
    provider_visit(
      contact,
      service: service,
      service_amount: 15_000,
      starts_at: first_at + 3.hours,
      ends_at: first_at + 210.minutes,
      status: 'cancelled',
      custom_attributes: {
        medelement_reception_code: SecureRandom.uuid,
        medelement_removed_at: (first_at + 1.hour).iso8601
      }
    )

    # 3. Early cancelled appointment for repeat_contact (removed > 1 hour before starts_at, no replacement)
    provider_visit(
      repeat_contact,
      service: service,
      service_amount: 10_000,
      starts_at: first_at + 5.hours,
      ends_at: first_at + 330.minutes,
      status: 'cancelled',
      custom_attributes: {
        medelement_reception_code: SecureRandom.uuid,
        medelement_removed_at: (first_at + 2.hours).iso8601
      }
    )

    # 4. True no-show appointment (removed < 1 hour before starts_at, no replacement; 12,000 KZT lost)
    no_show_contact = create(:contact, account: account)
    incoming(no_show_contact, at: first_at + 10.minutes)
    provider_visit(
      no_show_contact,
      service: service,
      service_amount: 12_000,
      starts_at: first_at + 4.hours,
      ends_at: first_at + 270.minutes,
      status: 'cancelled',
      custom_attributes: {
        medelement_reception_code: SecureRandom.uuid,
        medelement_removed_at: (first_at + 210.minutes).iso8601
      }
    )

    # WhatsApp touches for completed_apt
    create(
      :reminder,
      account: account,
      remindable: completed_apt,
      status: :completed,
      completed_at: first_at + 30.minutes,
      scheduled_at: first_at + 30.minutes,
      template_params: { 'name' => 'booking_reminder_1d' }
    )
    create(
      :reminder,
      account: account,
      remindable: completed_apt,
      status: :completed,
      completed_at: first_at + 45.minutes,
      scheduled_at: first_at + 45.minutes,
      template_params: { 'name' => 'booking_reminder_2h' }
    )
    create(
      :reminder,
      account: account,
      remindable: completed_apt,
      status: :completed,
      completed_at: first_at + 160.minutes,
      scheduled_at: first_at + 160.minutes,
      template_params: { 'name' => 'booking_feedback_request' }
    )

    result = report
    expect(result).to include(
      leads_count: 2,
      repeat_contacts_count: 1,
      attended_appointments_count: 1,
      rescheduled_appointments_count: 1,
      early_cancelled_appointments_count: 0,
      true_no_show_appointments_count: 1,
      net_attendance_rate_percent: 50.0,
      completed_revenue_kzt: 15_000,
      rescheduled_saved_revenue_kzt: 15_000,
      true_no_show_lost_revenue_kzt: 12_000
    )

    expect(result[:all_contacts_funnel]).to include(
      contacts_count: 3,
      booked_contacts_count: 3,
      attended_contacts_count: 1,
      primary_contacts_count: 2,
      repeat_contacts_count: 1
    )

    expect(result[:schedule_breakdown]).to include(
      total_appointments_count: 4,
      completed_count: 1,
      rescheduled_count: 1,
      early_cancelled_count: 1,
      true_no_show_count: 1,
      completed_revenue_kzt: 15_000,
      rescheduled_saved_revenue_kzt: 15_000,
      true_no_show_lost_revenue_kzt: 12_000,
      net_attendance_rate_percent: 50.0
    )

    expect(result[:whatsapp_touches]).to include(
      total_sent_count: 3,
      reminder_1d_sent_count: 1,
      reminder_1d_confirmed_count: 1,
      reminder_1d_confirmation_rate_percent: 100.0,
      reminder_2h_sent_count: 1,
      review_request_sent_count: 1
    )

    exec_report = Reports::MonthlyExecutiveReportService.new(account: account, target_month: '2026-10', now: now).perform
    expect(exec_report[:period_key]).to eq('2026-10')
    expect(exec_report[:summary_text]).to include('Состоявшиеся приёмы: 1 (на сумму 15 000 ₸)')
    expect(account.reload.custom_attributes.dig('monthly_executive_reports', '2026-10', 'period_label')).to eq('Октябрь 2026 г.')
  end
end
