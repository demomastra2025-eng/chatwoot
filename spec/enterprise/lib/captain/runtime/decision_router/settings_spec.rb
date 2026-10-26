# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Settings do
  let(:shipped) { YAML.safe_load(Rails.root.join('config/installation_config.yml').read).index_by { |config| config['name'] } }

  before { InstallationConfig.where(name: 'CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS').delete_all }

  it 'gives the routing chain time for a full attempt of every model by default' do
    per_model = Llm::FeatureProfile.for(:agent_routing).timeout_seconds

    expect(described_class.chain_budget_seconds).to eq(6.5)
    expect(described_class.chain_budget_seconds)
      .to be >= (per_model * Llm::DecisionChain::MAX_MODELS) + Llm::DecisionChain::MIN_ATTEMPT_SECONDS
  end

  it 'ships the same defaults in the installation config' do
    expect(shipped['CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS']['value'].to_f / 1000).to eq(described_class::CHAIN_BUDGET_SECONDS)
    expect(JSON.parse(shipped['CAPTAIN_AGENT_ROUTING_MODELS']['value']))
      .to eq(%w[perplexity/pplx-decider-v1.2 inception/mercury-decide microsoft/microsoft-decision-1])
      .and eq(Llm::DecisionChain::FEATURE_CHAINS['agent_routing'][:default])
  end

  it 'follows the platform setting within its bound' do
    create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS', value: '8000')
    expect(described_class.chain_budget_seconds).to eq(8.0)

    InstallationConfig.find_by(name: 'CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS').update!(value: '90000')
    expect(described_class.chain_budget_seconds).to eq(15)
  end

  # The owner's decision of 26.10: no confidence threshold and no escalation, so their old rows change nothing.
  it 'reads no threshold or escalation setting' do
    expect(described_class).not_to respond_to(:min_confidence, :escalation_timeout_seconds, :escalation_effort, :bounce_escalation?)
  end
end
