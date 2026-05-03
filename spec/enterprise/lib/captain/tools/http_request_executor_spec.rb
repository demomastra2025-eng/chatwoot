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
      contact: { id: 789, phone_number: 'customer-phone' },
      prompt_context: {
        contact: { id: 789, phone_number: 'customer-phone' },
        conversation: { id: 123, display_id: 456 }
      }
    }
  end
  let(:executor) { described_class.new(assistant: assistant, custom_tool: custom_tool, state: state) }
  let!(:lead_request_stub) do
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 200, body: '{"ok": true}')
  end

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
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

  it 'normalizes binary-encoded HTTP response bodies before returning them to Captain runtime' do
    custom_tool.update!(response_template: nil)
    binary_body = '{"status":"принято"}'.dup.force_encoding(Encoding::ASCII_8BIT)
    remove_request_stub(lead_request_stub)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 200, body: binary_body)

    result = nil
    expect do
      result = executor.call('lead_name' => 'Alice')
      JSON.generate([{ role: 'tool', content: result }])
    end.not_to output(/UTF-8 string passed as BINARY/).to_stderr

    expect(result).to eq('{"status":"принято"}')
    expect(result.encoding).to eq(Encoding::UTF_8)
  end

  it 'keeps raw upstream body hidden when result safety blocks details response' do
    custom_tool.update!(response_template: nil)
    remove_request_stub(lead_request_stub)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 200, body: '{"status":"blocked marker"}')
    safety_executor = described_class.new(
      assistant: assistant,
      custom_tool: custom_tool,
      state: state,
      feature: :assistant,
      enforce_safety: true
    )
    allow(Llm::SafetyPolicy).to receive(:check!) do |stage:, **|
      if stage == :tool_results
        raise Llm::SafetyPolicy::UnsafeContentError.new(
          feature: :assistant,
          stage: :tool_results,
          reason: :custom_blocklist
        )
      end

      Llm::SafetyPolicy::CheckResult.new(status: :allowed, feature: :assistant, stage: stage)
    end

    result = safety_executor.execute_with_details({ 'lead_name' => 'Alice' }, raise_on_http_error: false)

    expect(result[:response]).to include(
      blocked: true,
      formatted_body: 'ERROR: Tool result blocked by safety policy',
      stage: :tool_results
    )
    expect(result[:response]).not_to have_key(:body)
    expect(result[:response].to_json).not_to include('blocked marker')
  end

  it 'retries transient upstream errors for search apartments tool before failing over' do
    custom_tool.update!(slug: 'custom_search_apartments')
    allow(executor).to receive(:sleep)
    remove_request_stub(lead_request_stub)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return({ status: 502, body: 'bad gateway' }, { status: 200, body: '{"ok": true}' })

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('Lead accepted: true')
    expect(WebMock).to have_requested(:post, 'https://example.com/leads').twice
  end

  it 'retries transient upstream errors for idempotent GET tools' do
    custom_tool.update!(http_method: 'GET', request_template: nil)
    allow(executor).to receive(:sleep)
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads')
      .to_return({ status: 503, body: 'temporarily unavailable' }, { status: 200, body: '{"ok": true}' })

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('Lead accepted: true')
    expect(WebMock).to have_requested(:get, 'https://example.com/leads').twice
  end

  it 'retries network exceptions for idempotent GET tools' do
    custom_tool.update!(http_method: 'GET', request_template: nil)
    allow(executor).to receive(:sleep)
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads')
      .to_timeout
      .then
      .to_return(status: 200, body: '{"ok": true}')

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('Lead accepted: true')
    expect(WebMock).to have_requested(:get, 'https://example.com/leads').twice
  end

  it 'does not automatically retry arbitrary side-effectful POST tools' do
    remove_request_stub(lead_request_stub)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 502, body: 'bad gateway')

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('ERROR: HTTP request failed with status 502')
    expect(WebMock).to have_requested(:post, 'https://example.com/leads').once
  end

  it 'returns upstream validation details for non-retryable 422 failures' do
    remove_request_stub(lead_request_stub)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 422, body: '{"error":"invalid flat id"}')

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('ERROR: HTTP request failed with status 422: {"error":"invalid flat id"}')
    expect(WebMock).to have_requested(:post, 'https://example.com/leads').once
  end

  it 'sanitizes upstream validation details before logging or returning them' do
    remove_request_stub(lead_request_stub)
    allow(Rails.logger).to receive(:error)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 422, body: '{"error":"phone +770****4567 is invalid","phone":"+770****4567","token":"secret-value"}')

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('ERROR: HTTP request failed with status 422: {"error":"phone [REDACTED_PHONE] is invalid"}')
    expect(Rails.logger).to have_received(:error).with(/\[REDACTED_PHONE\]/)
    expect(Rails.logger).not_to have_received(:error).with(/\+770\*\*\*\*4567|secret-value|"phone"|"token"/)
  end

  it 'ignores top-level upstream JSON strings and arrays in validation failures' do
    remove_request_stub(lead_request_stub)
    allow(Rails.logger).to receive(:error)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 422, body: '["customer Alice +770****4567"]')

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('ERROR: HTTP request failed with status 422')
    expect(Rails.logger).not_to have_received(:error).with(/Alice|\+770\*\*\*\*4567|customer/)
  end

  it 'does not retry non-post tools that only share the search apartments slug' do
    custom_tool.update!(slug: 'custom_search_apartments', http_method: 'PUT')
    remove_request_stub(lead_request_stub)
    stub_request(:put, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_return(status: 502, body: 'bad gateway')

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('ERROR: HTTP request failed with status 502')
    expect(WebMock).to have_requested(:put, 'https://example.com/leads').once
  end

  it 'does not retry allowlisted POST tools on ambiguous network exceptions' do
    custom_tool.update!(slug: 'custom_search_apartments')
    remove_request_stub(lead_request_stub)
    stub_request(:post, 'https://example.com/leads')
      .with(body: '{"lead_name":"Alice","phone":"customer-phone"}')
      .to_timeout

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('ERROR: An error occurred while executing the request')
    expect(WebMock).to have_requested(:post, 'https://example.com/leads').once
  end
end
