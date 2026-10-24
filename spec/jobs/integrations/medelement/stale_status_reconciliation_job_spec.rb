require 'rails_helper'

RSpec.describe Integrations::Medelement::StaleStatusReconciliationJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:report) { Integrations::Medelement::StaleStatusReport.new(dry_run: false, days: 30) }
  let(:reconciler) { instance_double(Integrations::Medelement::StaleStatusReconciler, perform: report) }

  before { allow(Integrations::Medelement::StaleStatusReconciler).to receive(:new).and_return(reconciler) }

  def medelement_hook(**attributes)
    create(:integrations_hook, :medelement, account: create(:account).tap { |record| record.enable_features!('scheduling') }, **attributes)
  end

  it 'runs on the low queue, away from the sync queues' do
    expect(described_class.new.queue_name).to eq('low')
  end

  it 'reconciles the last 30 days with the default cap of one run' do
    described_class.perform_now(hook.id)

    expect(Integrations::Medelement::StaleStatusReconciler).to have_received(:new)
      .with(hook: hook, days: 30, dry_run: false, max_per_run: 1000)
    expect(reconciler).to have_received(:perform)
  end

  it 'can be run once for the whole history, as a dry run, without a cap' do
    described_class.perform_now(hook.id, days: nil, dry_run: true, max_per_run: nil)

    expect(Integrations::Medelement::StaleStatusReconciler).to have_received(:new)
      .with(hook: hook, days: nil, dry_run: true, max_per_run: nil)
  end

  it 'queues one run for every enabled MedElement hook when called without a hook, with the same options' do
    first = medelement_hook
    second = medelement_hook
    disabled = medelement_hook(status: 'disabled')
    options = { days: 30, dry_run: false, max_per_run: 1000 }

    expect { described_class.perform_now }
      .to have_enqueued_job(described_class).with(first.id, **options)
                                            .and have_enqueued_job(described_class).with(second.id, **options)
    expect { described_class.perform_now }.not_to have_enqueued_job(described_class).with(disabled.id, **options)
    expect(Integrations::Medelement::StaleStatusReconciler).not_to have_received(:new)
  end

  it 'spreads the queued runs over time' do
    first = medelement_hook
    second = medelement_hook
    options = { days: 30, dry_run: false, max_per_run: 1000 }

    freeze_time do
      expect { described_class.perform_now }
        .to have_enqueued_job(described_class).with(first.id, **options).at(Time.current)
                                              .and have_enqueued_job(described_class).with(second.id, **options).at(described_class::STAGGER.from_now)
    end
  end

  it 'drops a run for a hook that no longer exists' do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
