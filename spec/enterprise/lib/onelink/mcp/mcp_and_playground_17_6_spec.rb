# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'MCP and Captain Playground fixes (17.6)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let!(:assistant) do
    create(
      :captain_assistant,
      account: account,
      name: 'Координатор',
      description: 'Адрес в 2ГИС: https://go.2gis.com/clinic123. Отвечай вежливо.'
    )
  end

  after { Current.reset }

  describe 'Item 4a & 4b: OpenapiCatalog HTTPS internal env and /captain/playground tool' do
    let(:token) { admin.access_token || admin.create_access_token! }
    let(:auth_context) do
      instance_double(
        Onelink::Mcp::AuthContext,
        account: account,
        user: admin,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        token_value: token.token,
        administrator?: true,
        mcp_access_policy: Onelink::Mcp::AccessPolicy.new(
          account: account,
          user: admin,
          config: { sources: { openapi_read: true, openapi_write: true }, max_risk_level: 'high' }
        )
      )
    end
    let(:catalog) { Onelink::Mcp::OpenapiCatalog.new(auth_context: auth_context) }

    it 'dispatches internal Rack requests over HTTPS so force_ssl never returns 301/308' do
      captured_env = nil
      allow(Rails.application).to receive(:call) do |env|
        captured_env = env
        [200, { 'Content-Type' => 'application/json' }, ['{"payload":[]}']]
      end

      allow(Captain::ToolExecutionAuditService).to receive(:record)
      result = catalog.call_tool(name: 'api__get_account_details', arguments: {})

      expect(result[:isError]).to be(false)
      expect(captured_env['rack.url_scheme']).to eq('https')
      expect(captured_env['HTTPS']).to eq('on')
      expect(captured_env['HTTP_X_FORWARDED_PROTO']).to eq('https')
    end

    it 'exposes api__test_captain_workspace_playground for POST /api/v1/accounts/{account_id}/captain/playground' do
      tool = catalog.tools.find { |entry| entry[:name] == 'api__test_captain_workspace_playground' }

      expect(tool).to be_present
      expect(tool.dig(:_meta, :path)).to eq('/api/v1/accounts/{account_id}/captain/playground')
      request_props = tool.dig(:inputSchema, :properties, 'body', 'properties')
      expect(request_props).to include('message_content', 'playground_session_id', 'inbox_id', 'restore_session')
      expect(request_props['playground_session_id'].keys).to contain_exactly('type', 'description')
    end
  end

  describe 'Item 4c: Onelink::Mcp::ResponseRedactor and CaptainAssistantAdminTool preserve non-secret fields' do
    it 'preserves content, url, session_id, token counts and public 2GIS links while redacting true secrets' do
      list_tool = Captain::Tools::Account::ListCaptainAssistantsService.new(assistant, user: admin)
      raw_json = list_tool.execute
      parsed_assistants = JSON.parse(raw_json)
      entry = parsed_assistants['assistants'].find { |item| item['id'] == assistant.id }
      expect(entry['description']).to include('https://go.2gis.com/clinic123')

      redacted_json = Onelink::Mcp::ResponseRedactor.call(
        JSON.generate(
          assistants: parsed_assistants['assistants'],
          session_id: 'iso-12345',
          content: 'Обычный текст ответа',
          url: 'https://go.2gis.com/clinic123',
          reported_reasoning_tokens: 128,
          prompt_tokens: 512,
          access_token: 'super-secret-token',
          webhook_secret: 'whsec_12345',
          app_secret_key: 'meta_app_secret',
          pairing_code: '1234-5678',
          note: 'Auth header: Bearer eyJhbGciOiJIUzI1NiJ9.secretpayload'
        )
      )
      redacted = JSON.parse(redacted_json)

      expect(redacted).to include(
        'session_id' => 'iso-12345',
        'content' => 'Обычный текст ответа',
        'url' => 'https://go.2gis.com/clinic123',
        'reported_reasoning_tokens' => 128,
        'prompt_tokens' => 512,
        'access_token' => '[FILTERED]',
        'webhook_secret' => '[FILTERED]',
        'app_secret_key' => '[FILTERED]',
        'pairing_code' => '[FILTERED]'
      )
      expect(redacted['note']).to include('[FILTERED]')
      expect(redacted['note']).not_to include('eyJhbGciOiJIUzI1NiJ9')
    end
  end

  describe 'Item 4d & Item 3: Playground session isolation, timeout human_needed, and handoff status' do
    let(:path) { "/api/v1/accounts/#{account.id}/captain/playground" }
    let(:headers) { admin.create_new_auth_token }
    let(:runner) { instance_double(Captain::Assistant::AgentRunnerService) }

    before do
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
    end

    def post_playground(params)
      post path, params: params, headers: headers, as: :json
      %w[access-token token-type client expiry uid].each do |key|
        headers[key] = response.headers[key] if response.headers[key].present?
      end
      JSON.parse(response.body, symbolize_names: true)
    end

    it 'creates fresh isolated sessions when playground_session_id is omitted and preserves browser session via restore_session' do
      histories = []
      allow(runner).to receive(:generate_response) do |message_history:|
        histories << message_history
        { response: "Reply #{histories.size}" }
      end

      browser_init = post_playground(playground_action: 'session', restore_session: true)
      browser_id = browser_init.dig(:playground, :session_id)
      post_playground(message_content: 'Browser turn 1', playground_session_id: browser_id)

      case_one = post_playground(message_content: 'API case 1')
      case_two = post_playground(message_content: 'API case 2')

      expect(case_one.dig(:playground, :session_id)).to start_with('iso-')
      expect(case_two.dig(:playground, :session_id)).to start_with('iso-')
      expect(case_two.dig(:playground, :session_id)).not_to eq(case_one.dig(:playground, :session_id))
      expect(histories[1]).to eq([{ role: 'user', content: 'API case 1' }])
      expect(histories[2]).to eq([{ role: 'user', content: 'API case 2' }])

      restored_browser = post_playground(playground_action: 'session', restore_session: true)
      expect(restored_browser.dig(:playground, :session_id)).to eq(browser_id)
      expect(restored_browser.dig(:playground, :message_history).pluck(:content)).to eq(['Browser turn 1', 'Reply 1'])
    end

    it 'returns human_needed: true and status: timed_out when Playground times out' do
      allow(runner).to receive(:generate_response).and_raise(Timeout::Error, 'execution expired')

      body = post_playground(message_content: 'Долгий запрос')

      expect(response).to have_http_status(:success)
      expect(body).to include(
        response: nil,
        timed_out: true,
        status: 'timed_out',
        response_mode: 'human',
        human_needed: true
      )
    end

    it 'marks handoff and provider-error escalations with human_needed: true and status: handoff_required' do
      allow(runner).to receive(:generate_response).and_return(
        { 'response' => 'conversation_handoff', 'handoff_tool_called' => true }
      )

      body = post_playground(message_content: 'Позовите администратора')

      expect(response).to have_http_status(:success)
      expect(body).to include(human_needed: true, status: 'handoff_required')
    end
  end
end
