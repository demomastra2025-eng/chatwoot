# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Settings do
  let(:shipped) { YAML.safe_load(Rails.root.join('config/installation_config.yml').read).index_by { |config| config['name'] } }

  before do
    InstallationConfig.where(name: %w[CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS CAPTAIN_AGENT_ROUTING_ESCALATION_TIMEOUT_MS]).delete_all
  end

  it 'gives the routing chain time for a full attempt of every model, and the escalation 15 seconds, by default' do
    per_model = Llm::FeatureProfile.for(:agent_routing).timeout_seconds

    expect(described_class.chain_budget_seconds).to eq(6.5)
    expect(described_class.chain_budget_seconds)
      .to be >= (per_model * Llm::DecisionChain::MAX_MODELS) + Llm::DecisionChain::MIN_ATTEMPT_SECONDS
    expect(described_class.escalation_timeout_seconds).to eq(15.0)
  end

  it 'ships the same defaults in the installation config' do
    expect(shipped['CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS']['value'].to_f / 1000).to eq(described_class::CHAIN_BUDGET_SECONDS)
    expect(shipped['CAPTAIN_AGENT_ROUTING_ESCALATION_TIMEOUT_MS']['value'].to_f / 1000).to eq(described_class::ESCALATION_TIMEOUT_SECONDS)
    expect(JSON.parse(shipped['CAPTAIN_AGENT_ROUTING_MODELS']['value']))
      .to eq(%w[perplexity/pplx-decider-v1.2 inception/mercury-decide microsoft/microsoft-decision-1])
      .and eq(Llm::DecisionChain::FEATURE_CHAINS['agent_routing'][:default])
  end

  it 'follows the platform settings within their bounds' do
    create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS', value: '8000')
    create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_ESCALATION_TIMEOUT_MS', value: '90000')

    expect(described_class.chain_budget_seconds).to eq(8.0)
    expect(described_class.escalation_timeout_seconds).to eq(60)
  end
end
