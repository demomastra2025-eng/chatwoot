require 'rails_helper'

RSpec.describe Integrations::Medelement::DeltaProbeJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:probe) { instance_double(Integrations::Medelement::DeltaProbeService, perform: 'available') }

  def medelement_hook(**attributes)
    account = create(:account).tap { |record| record.enable_features!('scheduling') }
    create(:integrations_hook, :medelement, account: account, **attributes)
  end

  it 'runs on the scheduled jobs queue' do
    expect(described_class.new.queue_name).to eq('scheduled_jobs')
  end

  it 'probes the given hook' do
    allow(Integrations::Medelement::DeltaProbeService).to receive(:new).with(hook: hook).and_return(probe)

    described_class.perform_now(hook.id)

    expect(probe).to have_received(:perform)
  end

  it 'queues one probe for every enabled MedElement hook when called without a hook' do
    first = medelement_hook
    second = medelement_hook
    disabled = medelement_hook(status: 'disabled')
    other_app = create(:integrations_hook, account: create(:account))

    expect { described_class.perform_now }.to have_enqueued_job(described_class).with(first.id)
                                          .and have_enqueued_job(described_class).with(second.id)
    expect { described_class.perform_now }.not_to have_enqueued_job(described_class).with(disabled.id)
    expect { described_class.perform_now }.not_to have_enqueued_job(described_class).with(other_app.id)
  end

  it 'spreads the queued probes over time' do
    first = medelement_hook
    second = medelement_hook

    freeze_time do
      expect { described_class.perform_now }
        .to have_enqueued_job(described_class).with(first.id).at(Time.current)
        .and have_enqueued_job(described_class).with(second.id).at(described_class::STAGGER.from_now)
    end
  end

  it 'drops a probe for a hook that no longer exists' do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
