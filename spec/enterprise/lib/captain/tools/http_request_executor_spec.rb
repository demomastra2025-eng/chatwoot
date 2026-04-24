require 'rails_helper'

RSpec.describe Captain::Tools::HttpRequestExecutor do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:custom_tool) do
    create(
      :captain_custom_tool,
      :with_post,
      account: account,
      endpoint_url: 'https://example.com/leads',
      request_template: '{"lead_name":"{{ lead_name }}","phone":"{{ customer_phone }}"}',
      response_template: 'Lead accepted: {{ response.ok }}',
      param_schema: [
        { 'name' => 'lead_name', 'type' => 'string', 'description' => 'Lead name', 'source' => 'agent', 'required' => true },
        { 'name' => 'customer_phone', 'type' => 'string', 'description' => 'Phone from context', 'source' => 'context',
          'context_path' => 'contact.phone_number', 'required' => true }
      ]
    )
  end
  let(:state) do
    {
      account_id: account.id,
      assistant_id: assistant.id,
      conversation: { id: 123, display_id: 456 },
      contact: { id: 789, phone_number: '+77001234567' },
      prompt_context: {
        contact: { id: 789, phone_number: '+77001234567' },
        conversation: { id: 123, display_id: 456 }
      }
    }
  end
  let(:executor) { described_class.new(assistant: assistant, custom_tool: custom_tool, state: state) }

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"+77001234567"}')
      .to_return(status: 200, body: '{"ok": true}')
  end

  it 'executes request with templated body and formatted response' do
    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('Lead accepted: true')
    expect(WebMock).to(have_requested(:post, 'https://example.com/leads').with do |request|
      request.headers['X-Chatwoot-Account-Id'] == account.id.to_s &&
        request.headers['X-Chatwoot-Assistant-Id'] == assistant.id.to_s &&
        request.headers['X-Chatwoot-Conversation-Id'] == '123' &&
        request.headers['X-Chatwoot-Contact-Id'] == '789'
    end)
  end
end
