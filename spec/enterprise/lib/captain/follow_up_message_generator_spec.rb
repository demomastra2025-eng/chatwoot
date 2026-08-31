require 'rails_helper'

RSpec.describe Captain::FollowUpMessageGenerator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      name: 'Sales assistant',
      description: 'Help customers choose the right plan.',
      response_guidelines: ['Reply briefly.'],
      guardrails: ['Never invent discounts.']
    )
  end
  let(:settings) do
    {
      'prompt' => 'Continue naturally and use one clear call to action.'
    }
  end
  let(:step) do
    {
      'mode' => 'ai',
      'objective' => 'Ask whether the customer needs more plan details'
    }
  end
  let(:messages) do
    [
      { role: 'user', content: 'What does the Growth plan include?' },
      { role: 'assistant', content: 'It includes AI agents and telephony.' }
    ]
  end
  let(:service) do
    described_class.new(
      account: account,
      assistant: assistant,
      conversation_display_id: conversation.display_id,
      messages: messages,
      settings: settings,
      step: step,
      step_index: 1
    )
  end

  before do
    allow(Captain::ContextFields).to receive(:runtime_state_for).and_return(
      contact: { id: conversation.contact_id, name: 'Aset' },
      deal: { id: 42, stage_name: 'Qualification' }
    )
    allow(assistant).to receive(:prompt_context_state).with(
      anything,
      field_ids: []
    ).and_return(
      contact: { id: conversation.contact_id, name: 'Aset' },
      deal: { id: 42, stage_name: 'Qualification' }
    )
  end

  it 'generates a bounded message with the assistant identity, objective, history, and allowed business context' do
    expect(service).to receive(:make_api_call) do |model:, messages:, schema:|
      expect(model).to be_present
      expect(schema).to eq(Captain::FollowUpMessageSchema)
      expect(messages.first[:content]).to include(
        'Sales assistant',
        'Ask whether the customer needs more plan details',
        'Never invent discounts.'
      )
      expect(messages.last[:content]).to include('Growth plan', 'Qualification')
      {
        message: {
          'message' => 'Would you like a quick comparison with another plan?',
          'reason' => 'Offers one clear next action'
        },
        usage: { 'total_tokens' => 120 }
      }
    end

    expect(service.perform).to include(
      generated: true,
      message: 'Would you like a quick comparison with another plan?',
      reason: 'Offers one clear next action'
    )
  end

  it 'fails closed when the provider is unavailable' do
    allow(service).to receive(:make_api_call).and_return(error: 'raw provider details')

    expect(service.perform).to eq(generated: false, error: 'provider_unavailable')
  end

  it 'does not call the provider without a configured objective' do
    invalid_service = described_class.new(
      account: account,
      assistant: assistant,
      conversation_display_id: conversation.display_id,
      messages: messages,
      settings: settings,
      step: { mode: 'ai', objective: ' ' }
    )
    expect(invalid_service).not_to receive(:make_api_call)

    expect(invalid_service.perform).to eq(
      generated: false,
      error: 'Follow-up objective is missing'
    )
  end
end
