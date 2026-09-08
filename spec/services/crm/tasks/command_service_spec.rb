require 'rails_helper'

RSpec.describe Crm::Tasks::CommandService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:task) { create(:crm_task, account: account, status: account.crm_task_statuses.find_by!(code: 'todo')) }
  let(:service) do
    Crm::Tasks::CancelService.new(
      account: account, task: task, actor: actor,
      params: { cancellation_reason: 'Test', lock_version: task.lock_version }
    )
  end

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'publishes only after the outer transaction commits' do
    allow(service).to receive(:publish_realtime!)
    ApplicationRecord.transaction do
      service.perform
      expect(service).not_to have_received(:publish_realtime!)
    end
    expect(service).to have_received(:publish_realtime!).once
    expect(task.reload.cancelled_at).to be_present
  end

  it 'does not publish or retain task changes when the outer transaction rolls back' do
    task
    allow(service).to receive(:publish_realtime!)
    ApplicationRecord.transaction do
      service.perform
      raise ActiveRecord::Rollback
    end
    expect(service).not_to have_received(:publish_realtime!)
    expect(task.reload.cancelled_at).to be_nil
    expect(task.events.where(event_type: 'task_cancelled')).not_to exist
  end

  it 'does not publish a command rolled back in a savepoint' do
    task
    allow(service).to receive(:publish_realtime!)
    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) do
        service.perform
        raise ActiveRecord::Rollback
      end
    end
    expect(service).not_to have_received(:publish_realtime!)
    expect(task.reload.cancelled_at).to be_nil
  end

  describe 'deal closure' do
    let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }
    let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: pipeline.stages.find_by!(code: 'new')) }
    let(:close) do
      Crm::Deals::CloseWonService.new(
        account: account, deal: deal, actor: actor,
        params: { idempotency_key: 'close', lock_version: deal.lock_version }
      )
    end

    it 'cancels only open tasks, correlates events, and does not cancel again on retry' do
      task.update!(deal: deal)
      done = create(:crm_task, account: account, deal: deal, status: account.crm_task_statuses.find_by!(code: 'done'))
      cancelled = create(:crm_task, account: account, deal: deal, status: account.crm_task_statuses.find_by!(category: 'cancelled'))
      archived = create(:crm_task, account: account, deal: deal, archived_at: Time.current)
      versions = [done, cancelled, archived].map(&:lock_version)

      close.perform
      expect(task.reload).to have_attributes(cancellation_reason: 'deal_closed', cancelled_by_id: actor.id, archived_at: nil)
      expect([done, cancelled, archived].map { |record| record.reload.lock_version }).to eq(versions)
      expect(task.events.find_by!(event_type: 'task_cancelled').correlation_id).to eq(deal.events.find_by!(command_key: 'close').correlation_id)
      version = task.lock_version
      close.perform
      expect(task.reload.lock_version).to eq(version)
      expect(task.events.where(event_type: 'task_cancelled').count).to eq(1)
    end

    it 'rolls back the deal, tasks, receipts and realtime if any nested cancellation fails' do
      task.update!(deal: deal)
      another = create(:crm_task, account: account, deal: deal)
      original_stage = deal.stage_id
      actor
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
      allow(Crm::Tasks::CancelService).to receive(:new).and_wrap_original do |constructor, **args|
        command = constructor.call(**args)
        allow(command).to receive(:after_save!).and_raise('nested cancellation failed') if args[:task].id == another.id
        command
      end

      expect { close.perform }.to raise_error('nested cancellation failed')
      expect(deal.reload.stage_id).to eq(original_stage)
      expect(task.reload.cancelled_at).to be_nil
      expect(another.reload.cancelled_at).to be_nil
      expect(deal.events.where(command_key: 'close')).not_to exist
      expect(task.events.where(event_type: 'task_cancelled')).not_to exist
      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
    end
  end
end
