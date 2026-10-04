# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::FollowUpMessageGenerator do
  it 'uses the assistant-selected model in a real generation request' do
    account = create(:account)
    account.enable_features('captain_tasks')
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending)
    selected_model = 'openai/gpt-5.4'
    allow(Llm::Models).to receive(:valid_model_for?)
      .with(:assistant, selected_model, account: account).and_return(true)
    allow(Llm::Models).to receive(:canonical_model_name).with(selected_model).and_return(selected_model)
    assistant = create(:captain_assistant, account: account, config: { 'model' => selected_model })
    generator = described_class.new(
      account: account,
      assistant: assistant,
      conversation_display_id: conversation.display_id,
      messages: [{ role: 'user', content: 'Do you have availability tomorrow?' }],
      settings: { prompt: 'Be concise and helpful.' },
      step: { objective: 'Ask whether the customer needs more help.' }
    )
    allow(generator).to receive(:render_task_prompt).and_return('Follow-up generation instructions')
    expect(generator).to receive(:make_api_call).with(
      hash_including(model: selected_model, schema: Captain::FollowUpMessageSchema)
    ).and_return(error: nil, message: { 'message' => 'Would you like help with anything else?', 'reason' => 'The question was answered.' })

    expect(generator.perform).to include(generated: true, message: 'Would you like help with anything else?')
  end
end
