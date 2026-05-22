# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RedTeamSuite do
  it 'uses RubyLLM Tribunal red-team generators as a deterministic eval pack' do
    result = described_class.new.call

    expect(result.suite_id).to eq('captain.red_team')
    expect(result).to be_passed
    expect(result.cases.first[:actual][:attack_types]).to include('base64', 'ignore_instructions', 'dan')
  end
end
