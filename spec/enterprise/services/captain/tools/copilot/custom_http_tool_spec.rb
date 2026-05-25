require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CustomHttpTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+1234567890') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:custom_tool) do
    create(
      :captain_custom_tool,
      account: account,
      http_method: 'POST',
      endpoint_url: 'https://example.com/leads',
      request_template: '{"lead_name":"{{ lead_name }}","phone":"{{ customer_phone }}"}',
      response_template: nil,
      param_schema: [
        {
          'name' => 'lead_name',
          'type' => 'string',
          'description' => 'Lead name',
          'source' => 'agent',
          'required' => true
        },
        {
          'name' => 'customer_phone',
          'type' => 'string',
          'description' => 'Phone number from contact context',
          'source' => 'context',
          'context_path' => 'contact.phone_number',
          'required' => true
        }
      ]
    )
  end
  let(:tool) { described_class.new(assistant, custom_tool, conversation: conversation) }

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"+1234567890"}')
      .to_return(status: 200, body: '{"ok": true}')
  end

  describe '#parameters' do
    it 'builds RubyLLM parameter definitions from agent params' do
      params = tool.parameters

      expect(params.keys).to contain_exactly(:lead_name)
      expect(params[:lead_name].description).to eq('Lead name')
      expect(params[:lead_name].required).to be(true)
    end

    it 'delegates parameter contract building to the custom tool runtime contract' do
      allow(custom_tool).to receive(:runtime_parameters)
        .with(Captain::ToolAccess::SCOPE_ASSISTANT)
        .and_call_original

      tool.parameters

      expect(custom_tool).to have_received(:runtime_parameters).with(Captain::ToolAccess::SCOPE_ASSISTANT)
    end
  end

  describe '#execute' do
    it 'executes the custom tool with copilot conversation context' do
      result = tool.execute(lead_name: 'Alice')

      expect(result).to eq('{"ok": true}')
      expect(WebMock).to(have_requested(:post, 'https://example.com/leads').with do |request|
        request.headers['X-Chatwoot-Account-Id'] == account.id.to_s &&
          request.headers['X-Chatwoot-Assistant-Id'] == assistant.id.to_s &&
          request.headers['X-Chatwoot-Conversation-Id'] == conversation.id.to_s &&
          request.headers['X-Chatwoot-Conversation-Display-Id'] == conversation.display_id.to_s &&
          request.headers['X-Chatwoot-Contact-Id'] == contact.id.to_s &&
          request.headers['X-Chatwoot-Contact-Phone'] == contact.phone_number &&
          request.headers['X-Chatwoot-Tool-Slug'] == custom_tool.slug
      end)
    end

    it 'records tool execution with conversation runtime context' do
      captured_audit = nil
      allow(Captain::ToolExecutionAuditService).to receive(:record) do |*args, **kwargs|
        captured_audit = kwargs.presence || args.first
      end

      tool.execute(lead_name: 'Alice')

      expect(captured_audit).to include(
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        arguments: { lead_name: 'Alice' },
        result: '{"ok": true}',
        user: nil
      )
      expect(captured_audit[:runtime_context]).to include(
        conversation_id: conversation.id,
        conversation_display_id: conversation.display_id
      )
    end

    it 'returns a controlled tool error when tool arguments are blocked by safety policy' do
      account.update!(captain_runtime: { 'copilot_safety_blocklist' => ['blocked lead'] })

      result = tool.execute(lead_name: 'blocked lead')

      expect(result).to eq('ERROR: Tool arguments blocked by safety policy')
      expect(WebMock).not_to have_requested(:post, 'https://example.com/leads')
    end
  end
end
