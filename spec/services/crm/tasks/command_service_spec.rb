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

  it 'uses a stable fingerprint for semantically identical nested params' do
    first = Crm::Tasks::SaveFormService.new(
      account: account,
      task: task,
      actor: actor,
      params: {
        idempotency_key: 'nested',
        lock_version: task.lock_version,
        custom_attributes: { beta: ['two', { zeta: 2, alpha: 1 }], alpha: 'one' }
      }
    )
    second = Crm::Tasks::SaveFormService.new(
      account: account,
      task: task,
      actor: actor,
      params: {
        custom_attributes: { alpha: 'one', beta: ['two', { alpha: 1, zeta: 2 }] },
        lock_version: task.lock_version,
        idempotency_key: 'nested'
      }
    )

    expect(first.send(:command_fingerprint)).to eq(second.send(:command_fingerprint))
  end

  it 'hydrates catalog and context fields left null by an old writer before running a command' do
    assignee = create(:user, account: account, role: :agent)
    # rubocop:disable Rails/SkipsModelValidations -- Simulates a mixed-version writer against the expand schema.
    task.update_columns(
      activity_type: 'call', context_kind: nil, outcome: 'answered',
      task_outcome_id: nil, task_type_id: nil
    )
    # rubocop:enable Rails/SkipsModelValidations
    Crm::TaskOutcome.where(account: account).delete_all
    Crm::TaskType.where(account: account).delete_all

    Crm::Tasks::AssignService.new(
      account: account,
      task: task.reload,
      actor: actor,
      params: { assignee_id: assignee.id, lock_version: task.lock_version }
    ).perform

    expect(task.reload).to have_attributes(
      assignee_id: assignee.id,
      context_kind: 'personal',
      task_type_id: account.crm_task_types.find_by!(code: 'call').id,
      task_outcome_id: account.crm_task_outcomes.find_by!(code: 'answered').id,
      outcome: 'answered'
    )
  end

  %i[assign reschedule archive].each do |writer|
    it "preserves an unknown legacy outcome through #{writer}" do
      # rubocop:disable Rails/SkipsModelValidations -- Simulates a mixed-version writer against the expand schema.
      task.update_columns(
        activity_type: 'call', context_kind: nil, outcome: 'provider_custom',
        task_outcome_id: nil, task_type_id: nil
      )
      # rubocop:enable Rails/SkipsModelValidations

      run_legacy_writer(writer)

      expect(task.reload).to have_attributes(
        task_type_id: account.crm_task_types.find_by!(code: 'call').id,
        task_outcome_id: nil,
        outcome: 'provider_custom'
      )
    end
  end

  %i[reschedule archive].each do |writer|
    it "hydrates a known legacy outcome through #{writer}" do
      # rubocop:disable Rails/SkipsModelValidations -- Simulates a mixed-version writer against the expand schema.
      task.update_columns(
        activity_type: 'call', context_kind: nil, outcome: 'answered',
        task_outcome_id: nil, task_type_id: nil
      )
      # rubocop:enable Rails/SkipsModelValidations

      run_legacy_writer(writer)

      expect(task.reload).to have_attributes(
        task_type_id: account.crm_task_types.find_by!(code: 'call').id,
        task_outcome_id: account.crm_task_outcomes.find_by!(code: 'answered').id,
        outcome: 'answered'
      )
    end
  end

  it 'takes the catalog lock before the task row lock for a form save and does not reacquire it in nested commands' do
    assignee = create(:user, account: account, role: :agent)
    account.crm_task_outcomes.find_by!(code: 'busy').destroy!
    lock_order = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      lock_order << :catalog if sql.include?('pg_advisory_xact_lock')
      lock_order << :task if sql.match?(/FROM "crm_tasks".*FOR UPDATE/)
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      Crm::Tasks::SaveFormService.new(
        account: account, task: task, actor: actor,
        params: {
          assignee_id: assignee.id, idempotency_key: 'lock-order',
          lock_version: task.lock_version
        }
      ).perform
    end

    expect(lock_order).to eq(%i[catalog task task])
  end

  it 'completes an old-writer row after bootstrapping missing catalogs' do
    # rubocop:disable Rails/SkipsModelValidations -- Simulates a mixed-version writer against the expand schema.
    task.update_columns(task_type_id: nil, context_kind: nil)
    # rubocop:enable Rails/SkipsModelValidations
    Crm::TaskOutcome.where(account: account).delete_all
    Crm::TaskType.where(account: account).delete_all

    Crm::Tasks::CompleteService.new(
      account: account,
      task: task.reload,
      actor: actor,
      params: { lock_version: task.lock_version }
    ).perform

    expect(task.reload).to have_attributes(
      context_kind: 'personal',
      task_type_id: account.crm_task_types.find_by!(code: 'task').id,
      completed_at: be_present
    )
  end

  it 'cancels an old-writer row after bootstrapping missing catalogs' do
    # rubocop:disable Rails/SkipsModelValidations -- Simulates a mixed-version writer against the expand schema.
    task.update_columns(task_type_id: nil, context_kind: nil)
    # rubocop:enable Rails/SkipsModelValidations
    Crm::TaskOutcome.where(account: account).delete_all
    Crm::TaskType.where(account: account).delete_all

    Crm::Tasks::CancelService.new(
      account: account,
      task: task.reload,
      actor: actor,
      params: { cancellation_reason: 'No longer needed', lock_version: task.lock_version }
    ).perform

    expect(task.reload).to have_attributes(
      context_kind: 'personal',
      task_type_id: account.crm_task_types.find_by!(code: 'task').id,
      cancelled_at: be_present
    )
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

    it 'takes the catalog lock before deal and task row locks when closing a deal' do
      task.update!(deal: deal)
      account.crm_task_outcomes.find_by!(code: 'busy').destroy!
      lock_order = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        lock_order << :catalog if sql.include?('pg_advisory_xact_lock')
        lock_order << :row if sql.match?(/FROM "crm_(deals|tasks)".*FOR UPDATE/)
      end

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { close.perform }

      expect(lock_order.first).to eq(:catalog)
      expect(lock_order.drop(1)).to all(eq(:row))
    end
  end

  def run_legacy_writer(writer)
    send("run_legacy_#{writer}")
  end

  def run_legacy_assign
    assignee = create(:user, account: account, role: :agent)
    Crm::Tasks::AssignService.new(
      account: account, task: task.reload, actor: actor,
      params: { assignee_id: assignee.id, lock_version: task.lock_version }
    ).perform
  end

  def run_legacy_reschedule
    Crm::Tasks::RescheduleService.new(
      account: account, task: task.reload, actor: actor,
      params: { all_day: false, due_at: 1.day.from_now, lock_version: task.lock_version }
    ).perform
  end

  def run_legacy_archive
    Crm::Tasks::ArchiveService.new(
      account: account, task: task.reload, actor: actor,
      params: { lock_version: task.lock_version }, archived: true
    ).perform
  end
end
