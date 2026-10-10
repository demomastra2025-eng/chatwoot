require 'rails_helper'

RSpec.describe Crm::Appointments::AutomationService do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:start_stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:booked_stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:followup_stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won') }
  let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: start_stage) }
  let(:visit) do
    create(:scheduling_appointment, account: account, crm_deal: deal,
                                    custom_attributes: { medelement_reception_code: 'booked', medelement_provider_sync_status: 'succeeded' })
  end

  before { account.enable_features!('crm_deals') }

  def configure(rules, **settings)
    pipeline.update!(appointment_automation: { enabled: true, rules: rules, **settings })
    deal.reload
  end

  def rule(stage, conditions, scope: 'any')
    { stage_id: stage.id, scope: scope, conditions: conditions }
  end

  def evaluate
    described_class.new(deal: deal.reload).perform
  end

  it 'leaves new pipelines off and preserves existing inbound creation independently' do
    pipeline.update!(auto_create_deal_on_channel_contact: true)
    visit
    evaluate

    expect(deal.reload.stage_id).to eq(start_stage.id)
    expect(Crm::Appointments::Configuration.for(pipeline)['enabled']).to be false
    expect(pipeline.reload.auto_create_deal_on_channel_contact).to be true
  end

  it 'applies the first matching custom stage and deduplicates the same facts' do
    visit
    configure([rule(booked_stage, ['provider_confirmed']), rule(followup_stage, ['scheduled'])])
    evaluate
    events = deal.events.where(event_type: 'deal_stage_changed').count
    evaluate

    expect(deal.reload.stage_id).to eq(booked_stage.id)
    expect(deal.events.where(event_type: 'deal_stage_changed').count).to eq(events)
  end

  it 'keeps cancellation in a custom open follow-up stage and never defaults to lost' do
    visit.update!(status: 'cancelled')
    configure([rule(followup_stage, ['cancelled'])])
    evaluate

    expect(deal.reload.stage_id).to eq(followup_stage.id)
    expect(deal.closed_at).to be_nil
    expect(visit.reload.status).to eq('cancelled')
  end

  it 'only permits a won rule when its configured attendance requirement is met' do
    visit.update!(status: 'completed', custom_attributes: { medelement_reception_code: 'booked', provider_status_audit: { reason: 'provider_inactive' } }, source: 'medelement')
    configure([rule(won_stage, ['past'])], success_mode: 'any_attended')
    visit.update!(starts_at: 2.days.ago, ends_at: 2.days.ago + 30.minutes)
    evaluate
    expect(deal.reload.closed_at).to be_nil

    visit.update!(attendance_confirmed_at: Time.current)
    evaluate
    expect(deal.reload.stage_id).to eq(won_stage.id)
    expect(deal.closed_at).to be_present
  end

  it 'never automatically reopens a terminal deal after new appointment facts' do
    visit
    configure([rule(booked_stage, ['provider_confirmed'])])
    deal.update!(stage: won_stage, closed_at: Time.current)
    evaluate

    expect(deal.reload.stage_id).to eq(won_stage.id)
  end

  it 'preserves a manual stage change against queued old events and continues on new facts by default' do
    visit
    configure([rule(booked_stage, ['provider_confirmed']), rule(start_stage, ['cancelled'])])
    evaluate
    actor = create(:user, account: account)
    Crm::Deals::StageCommandService.new(account: account, deal: deal.reload, actor: actor,
                                      params: { stage_id: followup_stage.id, lock_version: deal.lock_version }).perform
    evaluate
    expect(deal.reload.stage_id).to eq(followup_stage.id)

    visit.update!(status: 'cancelled')
    evaluate
    expect(deal.reload.stage_id).to eq(start_stage.id)
    expect(deal.appointment_automation_state['paused_at']).to be_nil
  end

  it 'supports an optional pause after an explicit stage change' do
    visit
    configure([rule(booked_stage, ['provider_confirmed'])], manual_stage_change: 'pause')
    actor = create(:user, account: account)
    Crm::Deals::StageCommandService.new(account: account, deal: deal, actor: actor,
                                      params: { stage_id: followup_stage.id, lock_version: deal.lock_version }).perform
    visit.update!(status: 'confirmed')
    evaluate

    expect(deal.reload.stage_id).to eq(followup_stage.id)
    expect(deal.appointment_automation_state['paused_at']).to be_present
  end

  it 'reevaluates current cancellation facts instead of applying an old booked snapshot' do
    visit
    configure([rule(booked_stage, ['provider_confirmed']), rule(followup_stage, ['cancelled'])])
    visit.update!(status: 'cancelled')
    Crm::Appointments::EvaluateDealJob.perform_now(account.id, deal.id)

    expect(deal.reload.stage_id).to eq(followup_stage.id)
  end

  it 'keeps a failed stage requirement visible and does not invent missing fields' do
    visit
    create(:crm_stage_field_requirement, stage: booked_stage, field_key: 'description')
    deal.update!(description: nil)
    configure([rule(booked_stage, ['provider_confirmed'])])
    evaluate

    expect(deal.reload.stage_id).to eq(start_stage.id)
    expect(deal.appointment_automation_state['last_error']).to eq('DEAL_STAGE_REQUIRES_FIELDS')
    expect(deal.description).to be_nil
  end
end
