require 'rails_helper'

RSpec.describe 'CRM deal realtime events', :aggregate_failures do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }

  before do
    account.enable_features!('crm_deals')
  end

  def capture_dispatches
    captured_events = []
    allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, _timestamp, data|
      captured_events << [event_name, data]
    end
    captured_events
  end

  def bootstrap_pipeline
    Crm::Bootstrap::AccountService.new(account: account).perform
    account.crm_pipelines.find_by!(code: 'sales_pipeline')
  end

  it 'dispatches crm.deal.created when a deal is created' do
    captured_events = capture_dispatches

    deal = Crm::Deals::UpsertService.new(
      account: account,
      actor: actor,
      params: { title: 'Realtime deal' }
    ).perform

    created_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_DEAL_CREATED }
    expect(created_event).to be_present
    expect(created_event.last).to include(account: account, deal: deal)
    expect(created_event.last[:meta]).to include(event_type: 'deal_created')
    active_visit = deal.stage_visits.active.first!
    domain_event = deal.events.find_by!(event_type: 'deal_created')
    expect(active_visit.correlation_id).to eq(domain_event.correlation_id)
  end

  it 'dispatches crm.deal.updated when a deal is updated' do
    pipeline = bootstrap_pipeline
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: pipeline.stages.find_by!(code: 'new'))
    captured_events = capture_dispatches

    updated_deal = Crm::Deals::UpsertService.new(
      account: account,
      deal: deal,
      actor: actor,
      params: { title: 'Renamed deal', lock_version: deal.lock_version }
    ).perform

    updated_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_DEAL_UPDATED }
    expect(updated_event).to be_present
    expect(updated_event.last).to include(account: account, deal: updated_deal)
    expect(updated_event.last[:meta]).to include(event_type: 'deal_updated')
  end

  it 'dispatches crm.deal.stage_changed when a deal moves to another stage' do
    pipeline = bootstrap_pipeline
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: pipeline.stages.find_by!(code: 'new'))
    target_stage = pipeline.stages.find_by!(code: 'qualified')
    captured_events = capture_dispatches

    moved_deal = ApplicationRecord.transaction(requires_new: true) do
      result = Crm::Deals::TransitionService.new(
        account: account,
        deal: deal,
        actor: actor,
        params: { stage_id: target_stage.id, lock_version: deal.lock_version }
      ).perform
      expect(captured_events.none? { |name, _| name == Events::Types::CRM_DEAL_STAGE_CHANGED }).to be(true)
      result
    end

    stage_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_DEAL_STAGE_CHANGED }
    expect(stage_event).to be_present
    expect(stage_event.last).to include(account: account, deal: moved_deal)
    expect(stage_event.last[:meta]).to include(event_type: 'deal_stage_changed')
    expect(deal.stage_visits.count).to eq(2)
    expect(deal.stage_visits.where.not(exited_at: nil).count).to eq(1)
    active_visit = deal.stage_visits.active.first!
    domain_event = deal.events.find_by!(event_type: 'deal_stage_changed')
    expect(active_visit.stage_id).to eq(target_stage.id)
    expect(active_visit.correlation_id).to eq(domain_event.correlation_id)
  end

  it 'dispatches crm.deal.archived when a deal is archived' do
    pipeline = bootstrap_pipeline
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: pipeline.stages.find_by!(code: 'new'))
    captured_events = capture_dispatches

    archived_deal = Crm::Deals::ArchiveService.new(
      account: account,
      deal: deal,
      actor: actor,
      params: { lock_version: deal.lock_version },
      archived: true
    ).perform

    archived_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_DEAL_ARCHIVED }
    expect(archived_event).to be_present
    expect(archived_event.last).to include(account: account, deal: archived_deal)
    expect(archived_event.last[:meta]).to include(event_type: 'deal_archived')
  end

  it 'dispatches crm.deal.updated when a linked task changes' do
    account.enable_features!('crm_tasks')
    pipeline = bootstrap_pipeline
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: pipeline.stages.find_by!(code: 'new'))
    captured_events = capture_dispatches

    task = ApplicationRecord.transaction(requires_new: true) do
      Crm::Tasks::UpsertService.new(
        account: account,
        actor: actor,
        params: { deal_id: deal.id, title: 'Call customer', due_at: 1.day.from_now.iso8601 }
      ).perform
    end

    task_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_TASK_CREATED }
    expect(task_event).to be_present
    expect(task_event.last).to include(account: account, task: task)
    expect(task_event.last[:meta]).to include(event_type: 'task_created')

    updated_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_DEAL_UPDATED }
    expect(updated_event).to be_present
    expect(updated_event.last).to include(account: account, deal: deal)
    expect(updated_event.last[:meta]).to include(event_type: 'task_changed', task_id: task.id)
  end

  it 'dispatches crm.task.created for a standalone task' do
    account.enable_features!('crm_tasks')
    bootstrap_pipeline
    captured_events = capture_dispatches

    task = ApplicationRecord.transaction(requires_new: true) do
      Crm::Tasks::UpsertService.new(
        account: account,
        actor: actor,
        params: { title: 'Standalone follow-up', due_at: 1.day.from_now.iso8601 }
      ).perform
    end

    created_event = captured_events.find { |event_name, _data| event_name == Events::Types::CRM_TASK_CREATED }
    expect(created_event).to be_present
    expect(created_event.last).to include(account: account, task: task)
    expect(created_event.last[:meta]).to include(event_type: 'task_created')
    expect(captured_events.none? { |event_name, _data| event_name == Events::Types::CRM_DEAL_UPDATED }).to be(true)
  end
end
