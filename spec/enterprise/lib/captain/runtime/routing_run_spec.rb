# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::RoutingRun do
  let(:decision) { Captain::Runtime::DecisionRouter::Decision.new(key: 'route_agent_1', kind: 'agent', agent_ids: [1]) }
  let(:router) { instance_double(Captain::Runtime::DecisionRouter, decide: decision) }

  it 'decides on a thread of its own and hands the decision back' do
    run = described_class.new(router, parallel: true)

    expect(run.await).to eq(decision)
    run.settle
  end

  it 'decides on the calling thread when it is awaited without threads' do
    run = described_class.new(router, parallel: false)
    expect(router).not_to have_received(:decide)

    expect(run.await).to eq(decision)
    expect(router).to have_received(:decide).once
  end

  it 'raises the error of the router on the calling thread' do
    allow(router).to receive(:decide).and_raise(Captain::Runtime::DecisionRouter::UnavailableError.new(reason: 'decision_chain_unavailable'))

    expect { described_class.new(router, parallel: true).await }.to raise_error(Captain::Runtime::DecisionRouter::UnavailableError)
  end

  it 'turns an unexpected error into an unavailable router' do
    allow(router).to receive(:decide).and_raise(NoMethodError)

    expect { described_class.new(router, parallel: false).await }
      .to raise_error(Captain::Runtime::DecisionRouter::UnavailableError) { |error| expect(error.detail).to eq('NoMethodError') }
  end

  describe 'a reply suggestion that stops while the router decides' do
    let(:request_id) { SecureRandom.uuid }
    let(:slow_router) { instance_double(Captain::Runtime::DecisionRouter) }

    before { allow(slow_router).to receive(:decide) { sleep 2 } }

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    it 'stops at once when the manager cancels it, and does not wait for the decision afterwards' do
      run = described_class.new(slow_router, parallel: true)
      Captain::ReplySuggestion::RequestStore.request_cancel!(request_id)
      started = now

      expect do
        Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: now + 60) { run.await }
      end.to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect([error.kind, error.stage]).to eq([:cancelled, 'routing']) }
      run.settle

      expect(now - started).to be < 1.0
    end

    it 'stops at its deadline' do
      run = described_class.new(slow_router, parallel: true)

      expect do
        Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: now + 0.4) { run.await }
      end.to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect(error.kind).to eq(:deadline) }
    end
  end

  it 'is not waited for once the turn abandoned it' do
    slow = instance_double(Captain::Runtime::DecisionRouter)
    allow(slow).to receive(:decide) { sleep 2 }
    run = described_class.new(slow, parallel: true)
    run.abandon

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run.settle

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
  end

  it 'gives up when the decision does not finish in time, and does not wait for it a second time' do
    allow(router).to receive(:decide) { sleep 2 }
    run = described_class.new(router, parallel: true)
    allow(run).to receive(:wait_seconds).and_return(0.05, 5)

    expect { run.await }.to raise_error(Captain::Runtime::DecisionRouter::UnavailableError) { |error| expect(error.detail).to eq('router_timeout') }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run.settle
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
  end
end
