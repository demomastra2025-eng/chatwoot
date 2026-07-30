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
      communication_thread: { id: 11, display_id: 12, conversation_ids: [456], current_channel_key: 'conversation:456' },
      contact: { id: 789, phone_number: 'customer-phone' },
      prompt_context: {
        contact: { id: 789, phone_number: 'customer-phone' },
        conversation: { id: 123, display_id: 456 },
        communication_thread: { id: 11, display_id: 12, conversation_ids: [456], current_channel_key: 'conversation:456' }
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
        request.headers['X-Chatwoot-Communication-Thread-Display-Id'] == '12' &&
        request.headers['X-Chatwoot-Contact-Id'] == '789'
    end)
  end

  it 'sends configured headers with POST requests' do
    custom_tool.update!(
      param_schema: custom_tool.param_schema + [
        {
          'name' => 'tenant_id',
          'type' => 'string',
          'source' => 'fixed',
          'fixed_value' => 'tenant-42',
          'request_location' => 'header',
          'request_key' => 'X-Tenant-ID'
        }
      ]
    )

    executor.call('lead_name' => 'Alice')

    expect(WebMock).to have_requested(:post, 'https://example.com/leads')
      .with(headers: { 'X-Tenant-ID' => 'tenant-42' })
  end

  it 'does not let legacy custom headers override the configured request content type' do
    allow(custom_tool).to receive(:build_request_headers).and_return('Content-Type' => 'text/plain')

    executor.call('lead_name' => 'Alice')

    expect(WebMock).to have_requested(:post, 'https://example.com/leads')
      .with(headers: { 'Content-Type' => 'application/json' })
  end

  it 'does not let custom headers override authentication or OneLink metadata' do
    custom_tool.update!(
      auth_type: 'bearer',
      auth_config: { 'token' => 'real-token' },
      param_schema: custom_tool.param_schema + [
        {
          'name' => 'authorization_override',
          'type' => 'string',
          'source' => 'fixed',
          'fixed_value' => 'Bearer attacker-token',
          'request_location' => 'header',
          'request_key' => 'Authorization'
        },
        {
          'name' => 'account_override',
          'type' => 'string',
          'source' => 'fixed',
          'fixed_value' => '999999',
          'request_location' => 'header',
          'request_key' => 'X-Chatwoot-Account-Id'
        }
      ]
    )

    executor.call('lead_name' => 'Alice')

    expect(WebMock).to have_requested(:post, 'https://example.com/leads').with(
      headers: {
        'Authorization' => 'Bearer real-token',
        'X-Chatwoot-Account-Id' => account.id.to_s
      }
    )
  end

  it 'sends encoded query parameters and headers with GET requests' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      param_schema: [
        {
          'name' => 'search',
          'type' => 'string',
          'description' => 'Search text',
          'source' => 'agent',
          'required' => true,
          'request_location' => 'query',
          'request_key' => 'q'
        },
        {
          'name' => 'tenant_id',
          'type' => 'string',
          'source' => 'fixed',
          'fixed_value' => 'tenant-42',
          'request_location' => 'header',
          'request_key' => 'X-Tenant-ID'
        }
      ]
    )
    remove_request_stub(lead_request_stub)
    request_url = 'https://example.com/leads?q=%D0%90%D0%BB%D0%BC%D0%B0%D1%82%D1%8B+%26+%D0%90%D1%81%D1%82%D0%B0%D0%BD%D0%B0'
    stub_request(:get, request_url)
      .with(headers: { 'X-Tenant-ID' => 'tenant-42' })
      .to_return(status: 200, body: '{"ok": true}')

    preview = executor.preview('search' => 'Алматы & Астана')
    result = executor.call('search' => 'Алматы & Астана')

    expect(preview).to include(
      url: 'https://example.com/leads?q=REDACTED',
      headers: { 'X-Tenant-ID' => 'REDACTED' },
      resolved_params: {
        'search' => 'REDACTED',
        'tenant_id' => 'REDACTED'
      }
    )
    expect(result).to eq('Lead accepted: true')
    expect(WebMock).to have_requested(:get, request_url).with(headers: { 'X-Tenant-ID' => 'tenant-42' })
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

  it 'retries configured mutating requests with one stable idempotency key' do
    custom_tool.update!(
      http_options: {
        'retry' => { 'enabled' => true, 'max_attempts' => 2, 'backoff_ms' => 0, 'statuses' => [503] },
        'idempotency' => { 'enabled' => true }
      }
    )
    allow(executor).to receive(:sleep)
    remove_request_stub(lead_request_stub)
    idempotency_keys = []
    attempt = 0
    stub_request(:post, 'https://example.com/leads').to_return do |request|
      idempotency_keys << request.headers['Idempotency-Key']
      attempt += 1
      attempt == 1 ? { status: 503, body: 'retry' } : { status: 200, body: '{"ok": true}' }
    end

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('Lead accepted: true')
    expect(idempotency_keys.length).to eq(2)
    expect(idempotency_keys.uniq).to contain_exactly(a_string_matching(/\Aonelink-[0-9a-f]{48}\z/))
  end

  it 'aggregates page-parameter pagination until an empty items page' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [],
      http_options: {
        'pagination' => {
          'enabled' => true,
          'mode' => 'page_parameter',
          'parameter_name' => 'page',
          'start_page' => 1,
          'max_pages' => 5,
          'items_path' => 'data'
        }
      }
    )
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads?page=1').to_return(status: 200, body: '{"data":[{"id":1}]}')
    stub_request(:get, 'https://example.com/leads?page=2').to_return(status: 200, body: '{"data":[{"id":2}]}')
    stub_request(:get, 'https://example.com/leads?page=3').to_return(status: 200, body: '{"data":[]}')

    result = executor.call({})

    expect(JSON.parse(result)).to eq([{ 'id' => 1 }, { 'id' => 2 }])
    expect(WebMock).to have_requested(:get, 'https://example.com/leads?page=3').once
    expect(WebMock).not_to have_requested(:get, 'https://example.com/leads?page=4')
  end

  it 'follows same-origin next URL pagination and rejects an origin change' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [],
      http_options: {
        'pagination' => {
          'enabled' => true,
          'mode' => 'next_url',
          'max_pages' => 5,
          'items_path' => 'data',
          'next_url_path' => 'links.next'
        }
      }
    )
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads')
      .to_return(status: 200, body: '{"data":[{"id":1}],"links":{"next":"/leads?page=2"}}')
    stub_request(:get, 'https://example.com/leads?page=2')
      .to_return(status: 200, body: '{"data":[{"id":2}],"links":{"next":"https://other.example/leads?page=3"}}')

    result = executor.call({})

    expect(result).to eq('ERROR: The tool could not run because it is misconfigured')
    expect(WebMock).not_to have_requested(:get, 'https://other.example/leads?page=3')
  end

  it 'splits an agent array parameter into bounded sequential requests' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [
        {
          'name' => 'items',
          'type' => 'array',
          'description' => 'Items to process',
          'source' => 'agent',
          'required' => true,
          'request_location' => 'query',
          'request_key' => 'items'
        }
      ],
      http_options: {
        'batching' => { 'enabled' => true, 'items_parameter' => 'items', 'batch_size' => 2, 'interval_ms' => 0 }
      }
    )
    remove_request_stub(lead_request_stub)
    first_batch_stub = stub_request(:get, 'https://example.com/leads').with(query: { 'items' => '[1,2]' })
    second_batch_stub = stub_request(:get, 'https://example.com/leads').with(query: { 'items' => '[3]' })
    first_batch_stub.to_return(status: 200, body: '{"accepted":[1,2]}')
    second_batch_stub.to_return(status: 200, body: '{"accepted":[3]}')

    result = executor.call('items' => [1, 2, 3])

    expect(JSON.parse(result)).to eq([{ 'accepted' => [1, 2] }, { 'accepted' => [3] }])
  end

  it 'rejects batching payloads above the hard item limit before any request' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [
        { 'name' => 'items', 'type' => 'array', 'description' => 'Items', 'source' => 'agent', 'required' => true }
      ],
      http_options: {
        'batching' => { 'enabled' => true, 'items_parameter' => 'items', 'batch_size' => 100 }
      }
    )
    remove_request_stub(lead_request_stub)

    result = executor.call('items' => Array.new(501, 'item'))

    expect(result).to eq('ERROR: The tool could not run because items exceeds 500 items')
    expect(WebMock).not_to have_requested(:get, 'https://example.com/leads')
  end

  it 'stops a batched flow when the global runtime budget is exhausted' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [
        {
          'name' => 'items',
          'type' => 'array',
          'description' => 'Items',
          'source' => 'agent',
          'required' => true,
          'request_location' => 'query',
          'request_key' => 'items'
        }
      ],
      http_options: {
        'batching' => { 'enabled' => true, 'items_parameter' => 'items', 'batch_size' => 1, 'interval_ms' => 100 }
      }
    )
    remove_request_stub(lead_request_stub)
    allow(executor).to receive(:monotonic_time).and_return(0, 0, 0, 121)
    first_batch_stub = stub_request(:get, 'https://example.com/leads').with(query: { 'items' => '[1]' })
    first_batch_stub.to_return(status: 200, body: '{"accepted":[1]}')

    result = executor.call('items' => [1, 2])

    expect(result).to eq('ERROR: An error occurred while executing the request')
    expect(WebMock).not_to have_requested(:get, 'https://example.com/leads').with(query: { 'items' => '[2]' })
  end

  it 'follows bounded same-origin redirects' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [],
      http_options: { 'redirects' => { 'enabled' => true, 'max_redirects' => 2 } }
    )
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads')
      .to_return(status: 302, headers: { 'Location' => '/final' })
    stub_request(:get, 'https://example.com/final').to_return(status: 200, body: '{"ok":true}')

    result = executor.call({})

    expect(result).to eq('{"ok":true}')
    expect(WebMock).to have_requested(:get, 'https://example.com/final').once
  end

  it 'rejects an oversized content length before reading the response body' do
    stub_const("#{described_class}::MAX_RESPONSE_SIZE", 100)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response['Content-Length'] = '101'
    executor.instance_variable_set(:@flow_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120)

    expect(response).not_to receive(:read_body)
    expect { executor.send(:stream_response_body!, response) }
      .to raise_error(RuntimeError, 'Response size 101 bytes exceeds maximum allowed 100 bytes')
  end

  it 'interrupts a chunked response before appending bytes above the response limit' do
    stub_const("#{described_class}::MAX_RESPONSE_SIZE", 100)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    yielded_chunks = 0
    allow(response).to receive(:read_body) do |&block|
      ['a' * 100, 'b', 'not-read'].each do |chunk|
        yielded_chunks += 1
        block.call(chunk)
      end
    end
    executor.instance_variable_set(:@flow_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120)

    expect { executor.send(:stream_response_body!, response) }
      .to raise_error(RuntimeError, 'Response body size exceeds maximum allowed 100 bytes')
    expect(yielded_chunks).to eq(2)
  end

  it 'enforces the absolute deadline while a response is streaming' do
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    yielded_chunks = 0
    allow(response).to receive(:read_body) do |&block|
      %w[first second not-read].each do |chunk|
        yielded_chunks += 1
        block.call(chunk)
      end
    end
    executor.instance_variable_set(:@flow_deadline, 10)
    allow(executor).to receive(:monotonic_time).and_return(9, 11)

    expect { executor.send(:stream_response_body!, response) }
      .to raise_error(Timeout::Error, 'HTTP tool flow exceeded its runtime limit')
    expect(yielded_chunks).to eq(2)
  end

  it 'stops pagination before retaining responses above the aggregate byte budget' do
    stub_const("#{described_class}::MAX_RESPONSE_SIZE", 100)
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [],
      http_options: {
        'pagination' => {
          'enabled' => true,
          'mode' => 'page_parameter',
          'parameter_name' => 'page',
          'start_page' => 1,
          'max_pages' => 3,
          'items_path' => 'data'
        }
      }
    )
    remove_request_stub(lead_request_stub)
    page_body = JSON.generate('data' => ['x' * 50])
    stub_request(:get, 'https://example.com/leads?page=1').to_return(status: 200, body: page_body)
    stub_request(:get, 'https://example.com/leads?page=2').to_return(status: 200, body: page_body)

    result = executor.call({})

    expect(result).to eq('ERROR: The tool could not run because it is misconfigured')
    expect(WebMock).to have_requested(:get, 'https://example.com/leads?page=2').once
    expect(WebMock).not_to have_requested(:get, 'https://example.com/leads?page=3')
  end

  it 'stops pagination before retaining items above the aggregate item budget' do
    stub_const("#{described_class}::MAX_AGGREGATE_ITEMS", 2)
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [],
      http_options: {
        'pagination' => {
          'enabled' => true,
          'mode' => 'page_parameter',
          'parameter_name' => 'page',
          'start_page' => 1,
          'max_pages' => 3,
          'items_path' => 'data'
        }
      }
    )
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads?page=1').to_return(status: 200, body: '{"data":[1,2]}')
    stub_request(:get, 'https://example.com/leads?page=2').to_return(status: 200, body: '{"data":[3]}')

    result = executor.call({})

    expect(result).to eq('ERROR: The tool could not run because it is misconfigured')
    expect(WebMock).to have_requested(:get, 'https://example.com/leads?page=2').once
    expect(WebMock).not_to have_requested(:get, 'https://example.com/leads?page=3')
  end

  it 'applies the request budget to actual redirect network hops' do
    stub_const("#{described_class}::MAX_FLOW_REQUESTS", 1)
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [],
      http_options: { 'redirects' => { 'enabled' => true, 'max_redirects' => 2 } }
    )
    remove_request_stub(lead_request_stub)
    stub_request(:get, 'https://example.com/leads').to_return(status: 302, headers: { 'Location' => '/final' })
    stub_request(:get, 'https://example.com/final').to_return(status: 200, body: '{"ok":true}')

    result = executor.call({})

    expect(result).to eq('ERROR: The tool could not run because it is misconfigured')
    expect(WebMock).to have_requested(:get, 'https://example.com/leads').once
    expect(WebMock).not_to have_requested(:get, 'https://example.com/final')
  end

  it 'keeps one idempotency key across retries and redirects of a logical request' do
    custom_tool.update!(
      http_options: {
        'retry' => { 'enabled' => true, 'max_attempts' => 2, 'backoff_ms' => 0, 'statuses' => [503] },
        'redirects' => { 'enabled' => true, 'max_redirects' => 1 },
        'idempotency' => { 'enabled' => true }
      }
    )
    remove_request_stub(lead_request_stub)
    idempotency_keys = []
    final_attempt = 0
    stub_request(:post, 'https://example.com/leads').to_return do |request|
      idempotency_keys << request.headers['Idempotency-Key']
      { status: 307, headers: { 'Location' => '/final' } }
    end
    stub_request(:post, 'https://example.com/final').to_return do |request|
      idempotency_keys << request.headers['Idempotency-Key']
      final_attempt += 1
      final_attempt == 1 ? { status: 503, body: 'retry' } : { status: 200, body: '{"ok":true}' }
    end

    result = executor.call('lead_name' => 'Alice')

    expect(result).to eq('Lead accepted: true')
    expect(idempotency_keys.length).to eq(4)
    expect(idempotency_keys.uniq).to contain_exactly(a_string_matching(/\Aonelink-[0-9a-f]{48}\z/))
  end

  it 'uses different idempotency keys for separate logical batches' do
    custom_tool.update!(
      http_method: 'GET',
      request_template: nil,
      response_template: nil,
      param_schema: [
        {
          'name' => 'items',
          'type' => 'array',
          'description' => 'Items',
          'source' => 'agent',
          'required' => true,
          'request_location' => 'query',
          'request_key' => 'items'
        }
      ],
      http_options: {
        'idempotency' => { 'enabled' => true },
        'batching' => { 'enabled' => true, 'items_parameter' => 'items', 'batch_size' => 1 }
      }
    )
    remove_request_stub(lead_request_stub)
    idempotency_keys = []
    stub_request(:get, 'https://example.com/leads').with(query: { 'items' => '["same"]' }).to_return do |request|
      idempotency_keys << request.headers['Idempotency-Key']
      { status: 200, body: '{"ok":true}' }
    end

    result = executor.call('items' => %w[same same])

    expect(JSON.parse(result)).to eq([{ 'ok' => true }, { 'ok' => true }])
    expect(idempotency_keys.length).to eq(2)
    expect(idempotency_keys.uniq.length).to eq(2)
  end
end
