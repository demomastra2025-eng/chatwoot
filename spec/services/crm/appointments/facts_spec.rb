require 'rails_helper'

RSpec.describe Crm::Appointments::Facts do
  let(:account) { create(:account, reporting_timezone: 'Asia/Almaty') }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: stage) }
  let(:now) { Time.utc(2026, 10, 10, 19, 30) }

  def appointment(**attributes)
    create(:scheduling_appointment, account: account, crm_deal: deal, starts_at: now + 1.hour, ends_at: now + 90.minutes, **attributes)
  end

  def facts(at: now)
    described_class.new(deal: deal.reload, now: at)
  end

  it 'requires a successful provider booking rather than a local planned appointment' do
    local = appointment
    pending = appointment(custom_attributes: { medelement_reception_code: 'pending', medelement_provider_sync_status: 'pending' })
    confirmed = appointment(custom_attributes: { medelement_reception_code: 'booked', medelement_provider_sync_status: 'succeeded' })

    expect(described_class.provider_booked?(local)).to be false
    expect(described_class.provider_booked?(pending)).to be false
    expect(described_class.provider_booked?(confirmed)).to be true
  end

  it 'does not treat inactive provider records as attendance evidence' do
    inactive = appointment(source: 'medelement', status: 'completed', custom_attributes: { provider_status_audit: { reason: 'provider_inactive' } })
    explicit = appointment(source: 'medelement', status: 'completed', custom_attributes: { provider_status_audit: { reason: 'provider_explicit_completed' } })
    staff = appointment(source: 'medelement', status: 'completed', attendance_confirmed_at: now)

    expect(described_class.attended?(inactive)).to be false
    expect(described_class.attended?(explicit)).to be true
    expect(described_class.attended?(staff)).to be true
    explicit.update!(status: 'cancelled')
    expect(described_class.attended?(explicit.reload)).to be false
  end

  it 'uses the workspace day for today and tomorrow instead of the UTC day' do
    appointment(starts_at: Time.utc(2026, 10, 11, 1), ends_at: Time.utc(2026, 10, 11, 2))

    expect(facts.rule_matches?('scope' => 'any', 'conditions' => %w[scheduled today])).to be true
    expect(facts.rule_matches?('scope' => 'any', 'conditions' => ['tomorrow'])).to be false
    expect(facts.next_check_at).to be_nil
    pipeline.update!(appointment_automation: { enabled: true, rules: [{ stage_id: stage.id, scope: 'any', conditions: ['today'] }] })
    expect(facts.next_check_at).to eq(Time.utc(2026, 10, 11, 1))
  end

  it 'distinguishes any, all, selected and nearest appointment aggregation' do
    nearest = appointment(status: 'confirmed')
    later = appointment(status: 'cancelled', starts_at: now + 2.days, ends_at: now + 2.days + 30.minutes)
    deal.update!(selected_appointment_id: later.id)

    expect(facts.rule_matches?('scope' => 'any', 'conditions' => ['patient_confirmed'])).to be true
    expect(facts.rule_matches?('scope' => 'all', 'conditions' => ['patient_confirmed'])).to be false
    expect(facts.rule_matches?('scope' => 'selected', 'conditions' => ['cancelled'])).to be true
    expect(facts.rule_matches?('scope' => 'nearest', 'conditions' => ['patient_confirmed'])).to be true
    nearest.update!(status: 'no_show')
    expect(facts.rule_matches?('scope' => 'nearest', 'conditions' => ['patient_confirmed'])).to be false
  end

  it 'cannot close an eight-visit plan after one appointment or a cancelled required visit' do
    attended = appointment(status: 'completed', attendance_confirmed_at: now)
    cancelled = appointment(status: 'cancelled')
    pipeline.update!(appointment_automation: { success_mode: 'all_required_attended' })
    deal.update!(appointment_plan: Array.new(8) { |index| { id: index.to_s, label: "Visit #{index}", required: true, appointment_id: index.zero? ? attended.id : nil } })

    expect(facts.success?).to be false
    deal.update!(appointment_plan: [{ id: 'first', label: 'First', required: true, appointment_id: attended.id },
                                    { id: 'second', label: 'Second', required: true, appointment_id: cancelled.id }])
    expect(facts.success?).to be false
    deal.update!(appointment_plan: [{ id: 'first', label: 'First', required: true, appointment_id: attended.id }])
    expect(facts.success?).to be true
  end

  it 'requires the selected target when success is configured for that appointment' do
    appointment(status: 'completed', attendance_confirmed_at: now)
    target = appointment(status: 'scheduled')
    pipeline.update!(appointment_automation: { success_mode: 'selected_attended' })
    deal.update!(selected_appointment_id: target.id)

    expect(facts.success?).to be false
    target.update!(status: 'completed', attendance_confirmed_at: now)
    expect(facts.success?).to be true
  end

  it 'changes the fingerprint and schedules an end boundary without scanning the whole table' do
    visit = appointment(starts_at: now - 1.hour, ends_at: now + 30.minutes)
    pipeline.update!(appointment_automation: { enabled: true, rules: [{ stage_id: stage.id, scope: 'any', conditions: ['past'] }] })
    before = facts
    after = facts(at: visit.ends_at + 1.second)

    expect(before.next_check_at).to eq(visit.ends_at + 1.second)
    expect(after.fingerprint).not_to eq(before.fingerprint)
    expect(after.rule_matches?('scope' => 'any', 'conditions' => ['past'])).to be true
  end
end
