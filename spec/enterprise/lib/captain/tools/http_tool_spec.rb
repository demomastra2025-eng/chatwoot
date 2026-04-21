require 'rails_helper'

RSpec.describe Captain::Tools::HttpTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:custom_tool) { create(:captain_custom_tool, account: account) }
  let(:tool) { described_class.new(assistant, custom_tool) }
  let(:tool_context) { Struct.new(:state).new({}) }

  describe '#active?' do
    it 'returns true when custom tool is enabled' do
      custom_tool.update!(enabled: true)

      expect(tool.active?).to be true
    end

    it 'returns false when custom tool is disabled' do
      custom_tool.update!(enabled: false)

      expect(tool.active?).to be false
    end
  end

  describe '#perform' do
    before do
      allow(Resolv).to receive(:getaddresses).and_call_original
      allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
    end

    context 'with GET request' do
      before do
        custom_tool.update!(
          http_method: 'GET',
          endpoint_url: 'https://example.com/orders/123',
          response_template: nil
        )
        stub_request(:get, 'https://example.com/orders/123')
          .to_return(status: 200, body: '{"status": "success"}')
      end

      it 'executes GET request and returns response body' do
        result = tool.perform(tool_context)

        expect(result).to eq('{"status": "success"}')
        expect(WebMock).to have_requested(:get, 'https://example.com/orders/123')
      end
    end

    context 'with POST request' do
      before do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/orders',
          request_template: '{"order_id": "{{ order_id }}"}',
          response_template: nil
        )
        stub_request(:post, 'https://example.com/orders')
          .with(body: '{"order_id": "123"}', headers: { 'Content-Type' => 'application/json' })
          .to_return(status: 200, body: '{"created": true}')
      end

      it 'executes POST request with rendered body' do
        result = tool.perform(tool_context, order_id: '123')

        expect(result).to eq('{"created": true}')
        expect(WebMock).to have_requested(:post, 'https://example.com/orders')
          .with(body: '{"order_id": "123"}')
      end
    end

    {
      'PUT' => {
        request_method: :put,
        endpoint_url: 'https://example.com/orders/123',
        request_template: '{"status": "{{ status }}"}',
        params: { status: 'shipped' },
        expected_body: '{"status": "shipped"}'
      },
      'PATCH' => {
        request_method: :patch,
        endpoint_url: 'https://example.com/orders/123',
        request_template: '{"status": "{{ status }}"}',
        params: { status: 'delivered' },
        expected_body: '{"status": "delivered"}'
      },
      'DELETE' => {
        request_method: :delete,
        endpoint_url: 'https://example.com/orders/123',
        request_template: '{"reason": "{{ reason }}"}',
        params: { reason: 'duplicate' },
        expected_body: '{"reason": "duplicate"}'
      },
      'OPTIONS' => {
        request_method: :options,
        endpoint_url: 'https://example.com/orders',
        request_template: '{"probe": "{{ probe }}"}',
        params: { probe: 'allowed_methods' },
        expected_body: '{"probe": "allowed_methods"}'
      }
    }.each do |http_method, config|
      context "with #{http_method} request" do
        before do
          custom_tool.update!(
            http_method: http_method,
            endpoint_url: config[:endpoint_url],
            request_template: config[:request_template],
            response_template: nil
          )
          stub_request(config[:request_method], config[:endpoint_url])
            .with(
              body: config[:expected_body],
              headers: { 'Content-Type' => 'application/json' }
            )
            .to_return(status: 200, body: '{"ok": true}')
        end

        it "executes #{http_method} request with rendered body" do
          result = tool.perform(tool_context, **config[:params])

          expect(result).to eq('{"ok": true}')
          expect(WebMock).to have_requested(config[:request_method], config[:endpoint_url])
            .with(body: config[:expected_body])
        end
      end
    end

    context 'with HEAD request' do
      before do
        custom_tool.update!(
          http_method: 'HEAD',
          endpoint_url: 'https://example.com/orders/123',
          response_template: nil
        )
        stub_request(:head, 'https://example.com/orders/123')
          .to_return(status: 200, body: '')
      end

      it 'executes HEAD request without a response body' do
        result = tool.perform(tool_context)

        expect(result).to eq('')
        expect(WebMock).to have_requested(:head, 'https://example.com/orders/123')
      end
    end

    context 'with template variables in URL' do
      before do
        custom_tool.update!(
          endpoint_url: 'https://example.com/orders/{{ order_id }}',
          response_template: nil
        )
        stub_request(:get, 'https://example.com/orders/456')
          .to_return(status: 200, body: '{"order_id": "456"}')
      end

      it 'renders URL template with params' do
        result = tool.perform(tool_context, order_id: '456')

        expect(result).to eq('{"order_id": "456"}')
        expect(WebMock).to have_requested(:get, 'https://example.com/orders/456')
      end
    end

    context 'with filtered captain context variables' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 account_id: account.id,
                                 assistant_id: assistant.id,
                                 prompt_context: {
                                   contact: {
                                     phone_number: '+1234567890'
                                   },
                                   conversation: {
                                     custom_attributes: {
                                       order_id: 'ORD-42'
                                     }
                                   }
                                 }
                               })
      end

      before do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/contacts/{{ contact.phone_number }}',
          request_template: '{"order_id": "{{ conversation.custom_attributes.order_id }}"}',
          response_template: nil
        )
        stub_request(:post, 'https://example.com/contacts/+1234567890')
          .with(body: '{"order_id": "ORD-42"}')
          .to_return(status: 200, body: '{"ok": true}')
      end

      it 'renders custom tool templates using filtered prompt context' do
        result = tool.perform(tool_context_with_prompt_context)

        expect(result).to eq('{"ok": true}')
        expect(WebMock).to have_requested(:post, 'https://example.com/contacts/+1234567890')
          .with(body: '{"order_id": "ORD-42"}')
      end
    end

    context 'with appointment prompt context variables' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 account_id: account.id,
                                 assistant_id: assistant.id,
                                 prompt_context: {
                                   appointment: {
                                     starts_at: '2026-03-29T10:00:00Z',
                                     custom_attributes: {
                                       visit_room: 'B12'
                                     }
                                   }
                                 }
                               })
      end

      before do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/appointments',
          request_template: '{"starts_at": "{{ appointment.starts_at }}", "visit_room": "{{ appointment.custom_attributes.visit_room }}"}',
          response_template: nil
        )
        stub_request(:post, 'https://example.com/appointments')
          .with(body: '{"starts_at": "2026-03-29T10:00:00Z", "visit_room": "B12"}')
          .to_return(status: 200, body: '{"ok": true}')
      end

      it 'renders custom tool templates using appointment prompt context' do
        result = tool.perform(tool_context_with_prompt_context)

        expect(result).to eq('{"ok": true}')
        expect(WebMock).to have_requested(:post, 'https://example.com/appointments')
          .with(body: '{"starts_at": "2026-03-29T10:00:00Z", "visit_room": "B12"}')
      end
    end

    context 'with deal and task prompt context variables' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 account_id: account.id,
                                 assistant_id: assistant.id,
                                 prompt_context: {
                                   deal: {
                                     stage_name: 'Negotiation'
                                   },
                                   task: {
                                     status_name: 'In progress'
                                   }
                                 }
                               })
      end

      before do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/crm-context',
          request_template: '{"deal_stage": "{{ deal.stage_name }}", "task_status": "{{ task.status_name }}"}',
          response_template: nil
        )
        stub_request(:post, 'https://example.com/crm-context')
          .with(body: '{"deal_stage": "Negotiation", "task_status": "In progress"}')
          .to_return(status: 200, body: '{"ok": true}')
      end

      it 'renders custom tool templates using deal and task prompt context' do
        result = tool.perform(tool_context_with_prompt_context)

        expect(result).to eq('{"ok": true}')
        expect(WebMock).to have_requested(:post, 'https://example.com/crm-context')
          .with(body: '{"deal_stage": "Negotiation", "task_status": "In progress"}')
      end
    end

    context 'with mixed agent, context, and fixed parameters' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 prompt_context: {
                                   contact: {
                                     phone_number: '+1234567890'
                                   }
                                 }
                               })
      end

      before do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/leads',
          request_template: '{"lead_name":"{{ lead_name }}","phone":"{{ customer_phone }}","pipeline":"{{ pipeline }}"}',
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
            },
            {
              'name' => 'pipeline',
              'type' => 'string',
              'description' => 'Static pipeline name',
              'source' => 'fixed',
              'fixed_value' => 'sales',
              'required' => true
            }
          ]
        )
        stub_request(:post, 'https://example.com/leads')
          .with(body: '{"lead_name":"Alice","phone":"+1234567890","pipeline":"sales"}')
          .to_return(status: 200, body: '{"ok": true}')
      end

      it 'merges all parameter sources before rendering the request' do
        result = tool.perform(tool_context_with_prompt_context, lead_name: 'Alice')

        expect(result).to eq('{"ok": true}')
        expect(WebMock).to have_requested(:post, 'https://example.com/leads')
          .with(body: '{"lead_name":"Alice","phone":"+1234567890","pipeline":"sales"}')
      end
    end

    context 'with mixed agent, context, and fixed parameters in URL' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 prompt_context: {
                                   contact: {
                                     id: 42
                                   }
                                 }
                               })
      end

      before do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/hooks/{{ manager_name }}/changed/{{ pipeline }}?contact_id={{ customer_id }}',
          request_template: '{"ok":true}',
          response_template: nil,
          param_schema: [
            {
              'name' => 'manager_name',
              'type' => 'string',
              'description' => 'Manager chosen by the agent',
              'source' => 'agent',
              'required' => true
            },
            {
              'name' => 'customer_id',
              'type' => 'number',
              'description' => 'Contact id from context',
              'source' => 'context',
              'context_path' => 'contact.id',
              'required' => true
            },
            {
              'name' => 'pipeline',
              'type' => 'string',
              'description' => 'Static pipeline name',
              'source' => 'fixed',
              'fixed_value' => 'sales',
              'required' => true
            }
          ]
        )
        stub_request(:post, 'https://example.com/hooks/alice/changed/sales?contact_id=42')
          .with(body: '{"ok":true}')
          .to_return(status: 200, body: '{"ok": true}')
      end

      it 'resolves all parameter sources before rendering the URL template' do
        result = tool.perform(tool_context_with_prompt_context, manager_name: 'alice')

        expect(result).to eq('{"ok": true}')
        expect(WebMock).to have_requested(
          :post,
          'https://example.com/hooks/alice/changed/sales?contact_id=42'
        ).with(body: '{"ok":true}')
      end
    end

    context 'with a legacy tool using a reserved parameter name' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 prompt_context: {
                                   contact: {
                                     phone_number: '+1234567890'
                                   }
                                 }
                               })
      end

      before do
        custom_tool.update_columns(
          http_method: 'POST',
          endpoint_url: 'https://example.com/leads',
          request_template: '{"root_phone":"{{ contact.phone_number }}","agent_value":"{{ params.contact }}"}',
          response_template: nil,
          param_schema: [
            {
              'name' => 'contact',
              'type' => 'string',
              'description' => 'Legacy agent override',
              'source' => 'agent',
              'required' => true
            }
          ]
        )
        custom_tool.reload

        stub_request(:post, 'https://example.com/leads')
          .with(body: '{"root_phone":"+1234567890","agent_value":"override"}')
          .to_return(status: 200, body: '{"ok": true}')
      end

      it 'keeps system context at the root and exposes the agent value only under params' do
        result = tool.perform(tool_context_with_prompt_context, contact: 'override')

        expect(result).to eq('{"ok": true}')
        expect(WebMock).to have_requested(:post, 'https://example.com/leads')
          .with(body: '{"root_phone":"+1234567890","agent_value":"override"}')
      end
    end

    context 'when a required context parameter is missing' do
      let(:tool_context_with_prompt_context) do
        Struct.new(:state).new({
                                 prompt_context: {
                                   contact: {}
                                 }
                               })
      end

      before do
        custom_tool.update!(
          endpoint_url: 'https://example.com/leads',
          param_schema: [
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

      it 'returns a helpful error without executing the request' do
        result = tool.perform(tool_context_with_prompt_context)

        expect(result).to eq(
          'ERROR: The tool could not run because customer_phone is missing'
        )
        expect(WebMock).not_to have_requested(:any, 'https://example.com/leads')
      end
    end

    context 'with bearer token authentication' do
      before do
        custom_tool.update!(
          auth_type: 'bearer',
          auth_config: { 'token' => 'secret_bearer_token' },
          endpoint_url: 'https://example.com/data',
          response_template: nil
        )
        stub_request(:get, 'https://example.com/data')
          .with(headers: { 'Authorization' => 'Bearer secret_bearer_token' })
          .to_return(status: 200, body: '{"authenticated": true}')
      end

      it 'adds Authorization header with bearer token' do
        result = tool.perform(tool_context)

        expect(result).to eq('{"authenticated": true}')
        expect(WebMock).to have_requested(:get, 'https://example.com/data')
          .with(headers: { 'Authorization' => 'Bearer secret_bearer_token' })
      end
    end

    context 'with basic authentication' do
      before do
        custom_tool.update!(
          auth_type: 'basic',
          auth_config: { 'username' => 'user123', 'password' => 'pass456' },
          endpoint_url: 'https://example.com/data',
          response_template: nil
        )
        stub_request(:get, 'https://example.com/data')
          .with(basic_auth: %w[user123 pass456])
          .to_return(status: 200, body: '{"authenticated": true}')
      end

      it 'adds basic auth credentials' do
        result = tool.perform(tool_context)

        expect(result).to eq('{"authenticated": true}')
        expect(WebMock).to have_requested(:get, 'https://example.com/data')
          .with(basic_auth: %w[user123 pass456])
      end
    end

    context 'with API key authentication' do
      before do
        custom_tool.update!(
          auth_type: 'api_key',
          auth_config: { 'key' => 'api_key_123', 'location' => 'header', 'name' => 'X-API-Key' },
          endpoint_url: 'https://example.com/data',
          response_template: nil
        )
        stub_request(:get, 'https://example.com/data')
          .with(headers: { 'X-API-Key' => 'api_key_123' })
          .to_return(status: 200, body: '{"authenticated": true}')
      end

      it 'adds API key header' do
        result = tool.perform(tool_context)

        expect(result).to eq('{"authenticated": true}')
        expect(WebMock).to have_requested(:get, 'https://example.com/data')
          .with(headers: { 'X-API-Key' => 'api_key_123' })
      end
    end

    context 'with API key query authentication' do
      before do
        custom_tool.update!(
          auth_type: 'api_key',
          auth_config: { 'key' => 'api_key_123', 'location' => 'query', 'name' => 'api_key' },
          endpoint_url: 'https://example.com/data?details=true',
          response_template: nil
        )
        stub_request(:get, 'https://example.com/data?details=true&api_key=api_key_123')
          .to_return(status: 200, body: '{"authenticated": true}')
      end

      it 'adds API key query parameter to the request URL' do
        result = tool.perform(tool_context)

        expect(result).to eq('{"authenticated": true}')
        expect(WebMock).to have_requested(
          :get,
          'https://example.com/data?details=true&api_key=api_key_123'
        )
      end
    end

    context 'with response template' do
      before do
        custom_tool.update!(
          endpoint_url: 'https://example.com/orders/123',
          response_template: 'Order status: {{ response.status }}, ID: {{ response.order_id }}'
        )
        stub_request(:get, 'https://example.com/orders/123')
          .to_return(status: 200, body: '{"status": "shipped", "order_id": "123"}')
      end

      it 'formats response using template' do
        result = tool.perform(tool_context)

        expect(result).to eq('Order status: shipped, ID: 123')
      end
    end

    context 'when handling errors' do
      it 'returns generic error message on network failure' do
        custom_tool.update!(endpoint_url: 'https://example.com/data')
        stub_request(:get, 'https://example.com/data').to_raise(SocketError.new('Failed to connect'))

        result = tool.perform(tool_context)

        expect(result).to eq('ERROR: An error occurred while executing the request')
      end

      it 'returns generic error message on timeout' do
        custom_tool.update!(endpoint_url: 'https://example.com/data')
        stub_request(:get, 'https://example.com/data').to_timeout

        result = tool.perform(tool_context)

        expect(result).to eq('ERROR: An error occurred while executing the request')
      end

      it 'returns generic error message on HTTP 404' do
        custom_tool.update!(endpoint_url: 'https://example.com/data')
        stub_request(:get, 'https://example.com/data').to_return(status: 404, body: 'Not found')

        result = tool.perform(tool_context)

        expect(result).to eq('ERROR: HTTP request failed with status 404')
      end

      it 'returns generic error message on HTTP 500' do
        custom_tool.update!(endpoint_url: 'https://example.com/data')
        stub_request(:get, 'https://example.com/data').to_return(status: 500, body: 'Server error')

        result = tool.perform(tool_context)

        expect(result).to eq('ERROR: HTTP request failed with status 500')
      end

      it 'returns generic error message when a hostname resolves to mixed public and private IPs' do
        custom_tool.update!(endpoint_url: 'https://example.com/data')
        allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34', '127.0.0.1'])
        stub_request(:get, 'https://example.com/data').to_return(status: 200, body: '{"ok": true}')

        result = tool.perform(tool_context)

        expect(result).to eq('ERROR: An error occurred while executing the request')
        expect(WebMock).not_to have_requested(:get, 'https://example.com/data')
      end

      it 'logs error details' do
        custom_tool.update!(endpoint_url: 'https://example.com/data')
        stub_request(:get, 'https://example.com/data').to_raise(StandardError.new('Test error'))

        expect(Rails.logger).to receive(:error).with(/HttpTool execution error.*Test error/)

        tool.perform(tool_context)
      end
    end

    context 'when integrating with Toolable methods' do
      it 'correctly integrates URL rendering, body rendering, auth, and response formatting' do
        custom_tool.update!(
          http_method: 'POST',
          endpoint_url: 'https://example.com/users/{{ user_id }}/orders',
          request_template: '{"product": "{{ product }}", "quantity": {{ quantity }}}',
          auth_type: 'bearer',
          auth_config: { 'token' => 'integration_token' },
          response_template: 'Created order #{{ response.order_number }} for {{ response.product }}'
        )

        stub_request(:post, 'https://example.com/users/42/orders')
          .with(
            body: '{"product": "Widget", "quantity": 5}',
            headers: {
              'Authorization' => 'Bearer integration_token',
              'Content-Type' => 'application/json'
            }
          )
          .to_return(status: 200, body: '{"order_number": "ORD-789", "product": "Widget"}')

        result = tool.perform(tool_context, user_id: '42', product: 'Widget', quantity: 5)

        expect(result).to eq('Created order #ORD-789 for Widget')
      end
    end

    context 'with metadata headers' do
      let(:conversation) { create(:conversation, account: account) }
      let(:contact) { conversation.contact }
      let(:appointment) do
        create(
          :scheduling_appointment,
          account: account,
          resource: create(:scheduling_resource, account: account),
          service: create(:scheduling_service, account: account),
          contact: contact,
          conversation: conversation,
          status: 'confirmed',
          starts_at: Time.zone.parse('2026-03-29 10:00:00 UTC')
        )
      end
      let(:tool_context_with_state) do
        Struct.new(:state).new({
                                 account_id: account.id,
                                 assistant_id: assistant.id,
                                 conversation: {
                                   id: conversation.id,
                                   display_id: conversation.display_id
                                 },
                                 contact_inbox: {
                                   id: conversation.contact_inbox.id,
                                   hmac_verified: conversation.contact_inbox.hmac_verified
                                 },
                                 contact: {
                                   id: contact.id,
                                   email: contact.email,
                                   phone_number: contact.phone_number
                                 },
                                 appointment: {
                                   id: appointment.id,
                                   status: appointment.status,
                                   starts_at: appointment.starts_at.iso8601
                                 }
                               })
      end

      before do
        custom_tool.update!(
          endpoint_url: 'https://example.com/api/data',
          response_template: nil
        )
      end

      it 'includes metadata headers in GET request' do
        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Account-Id' => account.id.to_s,
                  'X-Chatwoot-Assistant-Id' => assistant.id.to_s,
                  'X-Chatwoot-Tool-Slug' => custom_tool.slug,
                  'X-Chatwoot-Conversation-Id' => conversation.id.to_s,
                  'X-Chatwoot-Conversation-Display-Id' => conversation.display_id.to_s,
                  'X-Chatwoot-Contact-Inbox-Id' => conversation.contact_inbox.id.to_s,
                  'X-Chatwoot-Contact-Inbox-Verified' => conversation.contact_inbox.hmac_verified.to_s,
                  'X-Chatwoot-Contact-Id' => contact.id.to_s,
                  'X-Chatwoot-Contact-Email' => contact.email,
                  'X-Chatwoot-Appointment-Id' => appointment.id.to_s,
                  'X-Chatwoot-Appointment-Status' => appointment.status,
                  'X-Chatwoot-Appointment-Starts-At' => appointment.starts_at.iso8601
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Account-Id' => account.id.to_s,
                  'X-Chatwoot-Contact-Inbox-Verified' => conversation.contact_inbox.hmac_verified.to_s,
                  'X-Chatwoot-Contact-Email' => contact.email,
                  'X-Chatwoot-Appointment-Id' => appointment.id.to_s
                })
      end

      it 'includes metadata headers in POST request' do
        custom_tool.update!(http_method: 'POST', request_template: '{"data": "test"}')

        stub_request(:post, 'https://example.com/api/data')
          .with(
            body: '{"data": "test"}',
            headers: {
              'Content-Type' => 'application/json',
              'X-Chatwoot-Account-Id' => account.id.to_s,
              'X-Chatwoot-Tool-Slug' => custom_tool.slug,
              'X-Chatwoot-Contact-Inbox-Verified' => conversation.contact_inbox.hmac_verified.to_s,
              'X-Chatwoot-Contact-Email' => contact.email
            }
          )
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to have_requested(:post, 'https://example.com/api/data')
      end

      it 'does not leak filtered-out contact fields through metadata headers' do
        tool_context_with_filtered_prompt_context = Struct.new(:state).new({
                                                                             account_id: account.id,
                                                                             assistant_id: assistant.id,
                                                                             prompt_context: {
                                                                               contact: {
                                                                                 id: contact.id
                                                                               },
                                                                               conversation: {
                                                                                 id: conversation.id,
                                                                                 display_id: conversation.display_id
                                                                               }
                                                                             },
                                                                             contact: {
                                                                               id: contact.id,
                                                                               email: contact.email,
                                                                               phone_number: contact.phone_number
                                                                             }
                                                                           })

        stub_request(:get, 'https://example.com/api/data')
          .with do |request|
            request.headers['X-Chatwoot-Contact-Id'] == contact.id.to_s &&
              request.headers['X-Chatwoot-Contact-Email'].blank? &&
              request.headers['X-Chatwoot-Contact-Phone'].blank?
          end
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_filtered_prompt_context)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
      end

      it 'includes metadata headers along with authentication headers' do
        custom_tool.update!(
          auth_type: 'bearer',
          auth_config: { 'token' => 'test_token' }
        )

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'Authorization' => 'Bearer test_token',
                  'X-Chatwoot-Account-Id' => account.id.to_s,
                  'X-Chatwoot-Contact-Inbox-Verified' => conversation.contact_inbox.hmac_verified.to_s,
                  'X-Chatwoot-Contact-Id' => contact.id.to_s
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
          .with(headers: {
                  'Authorization' => 'Bearer test_token',
                  'X-Chatwoot-Contact-Id' => contact.id.to_s
                })
      end

      it 'handles missing contact in tool context' do
        tool_context_no_contact = Struct.new(:state).new({
                                                           account_id: account.id,
                                                           assistant_id: assistant.id,
                                                           conversation: {
                                                             id: conversation.id,
                                                             display_id: conversation.display_id
                                                           },
                                                           contact_inbox: {
                                                             id: conversation.contact_inbox.id,
                                                             hmac_verified: conversation.contact_inbox.hmac_verified
                                                           }
                                                         })

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Account-Id' => account.id.to_s,
                  'X-Chatwoot-Conversation-Id' => conversation.id.to_s,
                  'X-Chatwoot-Contact-Inbox-Verified' => conversation.contact_inbox.hmac_verified.to_s
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_no_contact)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
      end

      it 'defaults contact inbox verified header to false when contact inbox is missing' do
        tool_context_without_contact_inbox = Struct.new(:state).new({
                                                                      account_id: account.id,
                                                                      assistant_id: assistant.id,
                                                                      conversation: {
                                                                        id: conversation.id,
                                                                        display_id: conversation.display_id
                                                                      },
                                                                      contact: {
                                                                        id: contact.id,
                                                                        email: contact.email
                                                                      }
                                                                    })

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Contact-Inbox-Verified' => 'false'
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_without_contact_inbox)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
          .with(headers: { 'X-Chatwoot-Contact-Inbox-Verified' => 'false' })
      end

      it 'includes contact phone when present' do
        contact.update!(phone_number: '+1234567890')
        tool_context_with_state.state[:contact][:phone_number] = '+1234567890'

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Contact-Phone' => '+1234567890'
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
          .with(headers: { 'X-Chatwoot-Contact-Phone' => '+1234567890' })
      end

      it 'uses filtered prompt context for metadata headers when available' do
        tool_context_with_state.state[:prompt_context] = {
          contact: {
            id: contact.id
          },
          appointment: {
            id: appointment.id
          }
        }

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Contact-Id' => contact.id.to_s,
                  'X-Chatwoot-Appointment-Id' => appointment.id.to_s
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to(have_requested(:get, 'https://example.com/api/data')
          .with do |request|
            request.headers['X-Chatwoot-Contact-Email'].blank? &&
              request.headers['X-Chatwoot-Appointment-Status'].blank? &&
              request.headers['X-Chatwoot-Appointment-Starts-At'].blank?
          end)
      end

      it 'does not fall back to raw metadata when prompt context disables the table' do
        tool_context_with_state.state[:prompt_context] = {}

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Account-Id' => account.id.to_s
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to(have_requested(:get, 'https://example.com/api/data')
          .with do |request|
            request.headers['X-Chatwoot-Contact-Id'].blank? &&
              request.headers['X-Chatwoot-Conversation-Id'].blank? &&
              request.headers['X-Chatwoot-Appointment-Id'].blank?
          end)
      end

      it 'includes unverified contact inbox status explicitly as false' do
        conversation.contact_inbox.update!(hmac_verified: false)
        tool_context_with_state.state[:contact_inbox][:hmac_verified] = false

        stub_request(:get, 'https://example.com/api/data')
          .with(headers: {
                  'X-Chatwoot-Contact-Inbox-Verified' => 'false'
                })
          .to_return(status: 200, body: '{"success": true}')

        tool.perform(tool_context_with_state)

        expect(WebMock).to have_requested(:get, 'https://example.com/api/data')
          .with(headers: { 'X-Chatwoot-Contact-Inbox-Verified' => 'false' })
      end
    end
  end
end
