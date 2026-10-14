# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::OutcomeDecisionEngine do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account, description: 'PRIVATE AGENT INSTRUCTIONS') }
  let(:conversation) { create(:conversation, account: account) }
  let(:transition) do
    ConversationStatusTransition.create!(account: account, conversation: conversation, actor: assistant,
                                         from_status: 'pending', to_status: 'resolved', source: 'captain')
  end
  let(:model) { 'microsoft/microsoft-decision-1' }
  let(:engine) { described_class.new(transition: transition, model: model) }
  let(:result) do
    Llm::OpenRouterDecisionClient::Result.new(choice: 'question_resolved', confidence: 0.9, model: "#{model}-20261009", provider: 'Azure')
  end

  def classify(expansion_available: true)
    engine.classify(messages: [{ role: 'customer', content: 'Спасибо, всё понятно' }], facts: { public_reply_sent: true },
                    reasons: [{ 'id' => 'question_resolved', 'label' => 'Вопрос решён' }, { 'id' => 'other', 'label' => 'Другое' }],
                    outcome: 'completion', locale: 'ru', expansion_available: expansion_available)
  end

  it 'uses only the bounded fragment and captured categories without inherited prompts, tools or generation parameters' do
    expect(Llm::Runtime).to receive(:decide) do |args|
      expect(args).to include(feature: :outcome_classification, model: model, account: account, conversation: conversation)
      expect(args[:input]).to include(outcome: 'completion', expansion_available: true)
      expect(args[:options][:decision_criteria].keys).to eq(%w[question_resolved other NEEDS_MORE_CONTEXT])
      expect(args[:input][:facts]).to eq(public_reply_sent: true)
      expect(args.keys & %i[temperature max_tokens tools messages]).to be_empty
      result
    end

    response = classify
    expect(response).to include('reason_id' => 'question_resolved', 'needs_more_context' => false, 'explanation' => '')
    expect(response['decision_metadata']).to include('served_model' => "#{model}-20261009", 'confidence' => 0.9)
  end

  it 'keeps insufficient evidence explicit on both the short and expanded fragment without inventing a textual explanation' do
    result.choice = described_class::MORE_CONTEXT
    allow(Llm::Runtime).to receive(:decide).and_return(result)
    [true, false].each do |available|
      expect(classify(expansion_available: available)).to include('reason_id' => 'other', 'needs_more_context' => true, 'explanation' => '')
    end
  end

  it 'defines a clinic-rule closure criterion for the built-in completion reason' do
    expect(described_class::BUILTIN_CRITERIA.fetch('closed_against_instructions')).to include('clinic instruction')
  end
end
