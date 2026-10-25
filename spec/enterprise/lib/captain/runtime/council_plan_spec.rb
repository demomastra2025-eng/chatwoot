# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::CouncilPlan do
  def parts(*ids) = ids.map { |id| { 'executor_agent_id' => id, 'fragment' => "part of #{id}" } }

  it 'accepts exactly one part per participant of the decision' do
    expect(described_class.validate!(parts(119, 84), [84, 119], candidate_ids: [84, 119, 120])).to eq(parts(119, 84))
  end

  it 'refuses a part for an agent the router did not choose, a missing participant and a second part of one agent' do
    expect { described_class.validate!(parts(84, 120), [84, 119], candidate_ids: [84, 119, 120]) }.to raise_error(described_class::MismatchError)
    expect { described_class.validate!(parts(84), [84, 119], candidate_ids: [84, 119, 120]) }.to raise_error(described_class::MismatchError)
    expect { described_class.validate!(parts(84, 84, 119), [84, 119], candidate_ids: [84, 119]) }.to raise_error(described_class::MismatchError)
  end

  it 'refuses a council of one agent and a participant that is not an agent of the turn' do
    expect { described_class.validate!(parts(84), [84], candidate_ids: [84, 119]) }.to raise_error(described_class::MismatchError)
    expect { described_class.validate!(parts(84, 7), [7, 84], candidate_ids: [84, 119]) }.to raise_error(described_class::MismatchError)
  end
end
