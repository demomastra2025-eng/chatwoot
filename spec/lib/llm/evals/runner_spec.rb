# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Runner do
  it 'lists offline and live eval packs with explicit cost/runtime metadata' do
    ids = Llm::Evals::PackRegistry.catalog.map { |pack| pack[:id] }

    expect(ids).to include(
      'llm.moderation',
      'captain.tool_safety',
      'captain.ai_voice_trace',
      'captain.conversation_completion'
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
    moderation = instance_double(Llm::Evals::Result, total_count: 1, passed_count: 1, failed_count: 0, error_count: 0, passed?: true,
                                                     to_h: { suite_id: 'llm.moderation' })
    safety = instance_double(Llm::Evals::Result, total_count: 1, passed_count: 1, failed_count: 0, error_count: 0, passed?: true,
                                                 to_h: { suite_id: 'captain.tool_safety' })
    voice = instance_double(Llm::Evals::Result, total_count: 1, passed_count: 1, failed_count: 0, error_count: 0, passed?: true,
                                                to_h: { suite_id: 'captain.ai_voice_trace' })

    allow(Llm::Evals::ModerationSuite).to receive(:new).and_return(instance_double(Llm::Evals::ModerationSuite, call: moderation))
    allow(Captain::Evals::ToolSafetySuite).to receive(:new).and_return(instance_double(Captain::Evals::ToolSafetySuite, call: safety))
    allow(Captain::Evals::AiVoiceTraceSuite).to receive(:new).and_return(instance_double(Captain::Evals::AiVoiceTraceSuite, call: voice))
    allow(Captain::Evals::ConversationCompletionSuite).to receive(:new)

    result = described_class.new.call

    expect(result.to_h).to include(
      status: 'pass',
      suite_count: 3,
      total_count: 3
    )
    expect(Captain::Evals::ConversationCompletionSuite).not_to have_received(:new)
  end
end
