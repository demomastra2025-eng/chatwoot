require 'rails_helper'
require 'rake'

RSpec.describe Rake::Task do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    Rails.application.load_tasks unless described_class.task_defined?('medelement:delta_misses')
  end

  it 'prints a code hash and field names without the raw reception code' do
    Integrations::Medelement::DeltaMiss.create!(
      hook: hook, reception_code: 'fake-reception-code', change_marker: 'marker-1',
      kind: 'changed', classification: 'unexplained', changed_fields: %w[starts_at],
      detected_at: Time.current
    )
    task = described_class['medelement:delta_misses']
    task.reenable

    expect { task.invoke(hook.id, 7) }.to output(/changed \| unexplained \| starts_at/).to_stdout
    task.reenable
    expect { task.invoke(hook.id, 7) }.not_to output(/fake-reception-code/).to_stdout
  end

  describe 'medelement:reconcile_stale_statuses' do
    let(:task) { described_class['medelement:reconcile_stale_statuses'] }
    let(:report) do
      Integrations::Medelement::StaleStatusReport.new(dry_run: true, days: nil).tap do |value|
        value.examine!
        value.transition!('scheduled', 'completed')
        value.remaining = 0
      end
    end
    let(:reconciler) { instance_double(Integrations::Medelement::StaleStatusReconciler, perform: report) }

    before do
      hook
      Rails.application.load_tasks unless described_class.task_defined?('medelement:reconcile_stale_statuses')
      task.reenable
      allow(Integrations::Medelement::StaleStatusReconciler).to receive(:new).and_return(reconciler)
    end

    it 'is a dry run for the last 30 days unless told otherwise, and prints the counts per status' do
      expect { task.invoke(account.id) }.to output(/last 30 days, DRY RUN, nothing is written/).to_stdout
      task.reenable
      expect { task.invoke(account.id) }.to output(/scheduled -> completed: 1\nexamined 1: would change 1/).to_stdout

      expect(Integrations::Medelement::StaleStatusReconciler).to have_received(:new)
        .with(hook: hook, days: 30, dry_run: true, max_per_run: nil).twice
    end

    it 'reads the whole history with "all" and applies only with an explicit false' do
      expect { task.invoke(account.id, 'all', 'false') }.to output(/whole history, APPLYING/).to_stdout

      expect(Integrations::Medelement::StaleStatusReconciler).to have_received(:new)
        .with(hook: hook, days: nil, dry_run: false, max_per_run: nil)
    end

    it 'takes an optional cap for one invocation' do
      expect { task.invoke(account.id, '90', 'true', '200') }.to output(/last 90 days/).to_stdout

      expect(Integrations::Medelement::StaleStatusReconciler).to have_received(:new)
        .with(hook: hook, days: 90, dry_run: true, max_per_run: 200)
    end

    it 'refuses anything unclear instead of guessing, in particular a mistyped dry_run' do
      expect { task.invoke(account.id, '30', 'flase') }.to raise_error(ArgumentError, /dry_run/)
      task.reenable
      expect { task.invoke(account.id, 'soon') }.to raise_error(ArgumentError, /days/)
      task.reenable
      expect { task.invoke(account.id, '30', 'true', '0') }.to raise_error(ArgumentError, /max_per_run/)
      task.reenable
      expect { task.invoke('x') }.to raise_error(ArgumentError, /account/)
      expect(Integrations::Medelement::StaleStatusReconciler).not_to have_received(:new)
    end

    it 'stops with a failure status and says why when the run was cut short' do
      report.aborted = 'sync_busy'

      expect { expect { task.invoke(account.id) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) } }
        .to output(/STOPPED: sync_busy/).to_stdout
    end
  end
end
