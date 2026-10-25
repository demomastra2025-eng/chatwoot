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

  it 'gives up when the decision does not finish in time' do
    allow(router).to receive(:decide) { sleep 2 }
    run = described_class.new(router, parallel: true)
    allow(run).to receive(:wait_seconds).and_return(0.05)

    expect { run.await }.to raise_error(Captain::Runtime::DecisionRouter::UnavailableError) { |error| expect(error.detail).to eq('router_timeout') }
  end
end
