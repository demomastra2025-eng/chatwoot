# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Runner do
  it 'lists offline and live eval packs with explicit cost/runtime metadata' do
    ids = Llm::Evals::PackRegistry.catalog.map { |pack| pack[:id] }

    expect(ids).to include(
      'llm.moderation',
      'captain.tool_safety',
      'captain.confirmation_safety',
      'captain.ai_voice_trace',
      'captain.voice_scenarios',
      'captain.event_contract_trace',
      'captain.knowledge_rag_trace',
      'captain.product_case_correctness',
      'captain.scenarios',
      'captain.scenario_simulation',
      'captain.scenario_red_team',
      'openrouter.contracts',
      'captain.red_team',
      'captain.conversation_completion'
    )
    expect(Llm::Evals::PackRegistry.find!('captain.scenario_simulation').to_h).to include(
      live_model: true,
      requires_account: true,
      default_enabled: false
    )
    expect(Llm::Evals::PackRegistry.find!('captain.conversation_completion').to_h).to include(
      live_model: true,
      requires_account: true,
      default_enabled: false
    )
    expect(Llm::Evals::PackRegistry.find!('captain.ai_voice_trace').to_h).to include(
      live_model: false,
      deterministic: true,
      default_enabled: true
    )
  end

  it 'runs only default deterministic packs unless live packs are explicitly requested' do
    moderation = eval_result_double('llm.moderation')
    safety = eval_result_double('captain.tool_safety')
    confirmation = eval_result_double('captain.confirmation_safety')
    voice = eval_result_double('captain.ai_voice_trace')
    voice_scenarios = eval_result_double('captain.voice_scenarios')
    event_contract = eval_result_double('captain.event_contract_trace')
    knowledge = eval_result_double('captain.knowledge_rag_trace')
    product_cases = eval_result_double('captain.product_case_correctness')
    scenarios = eval_result_double('captain.scenarios')
    openrouter_contracts = eval_result_double('openrouter.contracts')
    red_team = eval_result_double('captain.red_team')

    allow(Llm::Evals::ModerationSuite).to receive(:new)
      .and_return(instance_double(Llm::Evals::ModerationSuite, call: moderation))
    allow(Captain::Evals::ToolSafetySuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::ToolSafetySuite, call: safety))
    allow(Captain::Evals::ConfirmationSafetySuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::ConfirmationSafetySuite, call: confirmation))
    allow(Captain::Evals::AiVoiceTraceSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::AiVoiceTraceSuite, call: voice))
    allow(Captain::Evals::VoiceScenarioSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::VoiceScenarioSuite, call: voice_scenarios))
    allow(Captain::Evals::EventContractTraceSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::EventContractTraceSuite, call: event_contract))
    allow(Captain::Evals::KnowledgeRagTraceSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::KnowledgeRagTraceSuite, call: knowledge))
    allow(Captain::Evals::ProductCaseCorrectnessSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::ProductCaseCorrectnessSuite, call: product_cases))
    allow(Captain::Evals::ScenarioSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::ScenarioSuite, call: scenarios))
    allow(Llm::Evals::OpenRouterContractSuite).to receive(:new)
      .and_return(instance_double(Llm::Evals::OpenRouterContractSuite, call: openrouter_contracts))
    allow(Captain::Evals::RedTeamSuite).to receive(:new)
      .and_return(instance_double(Captain::Evals::RedTeamSuite, call: red_team))
    allow(Captain::Evals::ScenarioSimulationSuite).to receive(:new)
    allow(Captain::Evals::ScenarioRedTeamSuite).to receive(:new)
    allow(Captain::Evals::ConversationCompletionSuite).to receive(:new)

    result = described_class.new.call

    expect(result.to_h).to include(
      status: 'pass',
      suite_count: 11,
      total_count: 11
    )
    expect(Captain::Evals::ScenarioSimulationSuite).not_to have_received(:new)
    expect(Captain::Evals::ScenarioRedTeamSuite).not_to have_received(:new)
    expect(Captain::Evals::ConversationCompletionSuite).not_to have_received(:new)
  end

  def eval_result_double(suite_id)
    instance_double(
      Llm::Evals::Result,
      total_count: 1,
      passed_count: 1,
      failed_count: 0,
      error_count: 0,
      passed?: true,
      to_h: { suite_id: suite_id }
    )
  end
end
