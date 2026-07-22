require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::CustomTools', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/custom_tools' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns success status' do
        create_list(:captain_custom_tool, 3, account: account)
        get "/api/v1/accounts/#{account.id}/captain/custom_tools",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(3)
      end
    end

    context 'when it is an admin' do
      it 'returns success status and custom tools' do
        create_list(:captain_custom_tool, 5, account: account)
        get "/api/v1/accounts/#{account.id}/captain/custom_tools",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(5)
      end

      it 'returns enabled and disabled custom tools for management' do
        enabled_tool = create(:captain_custom_tool, account: account, enabled: true)
        disabled_tool = create(:captain_custom_tool, account: account, enabled: false)
        get "/api/v1/accounts/#{account.id}/captain/custom_tools",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].map { |tool| tool[:id] }).to contain_exactly(enabled_tool.id, disabled_tool.id)
        expect(json_response[:payload].map { |tool| tool[:enabled] }).to contain_exactly(true, false)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let(:custom_tool) { create(:captain_custom_tool, account: account) }

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns success status and custom tool' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(custom_tool.id)
        expect(json_response[:title]).to eq(custom_tool.title)
      end
    end

    context 'when custom tool does not exist' do
      it 'returns not found status' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools/999999",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/custom_tools' do
    let(:valid_attributes) do
      {
        custom_tool: {
          title: 'Fetch Order Status',
          description: 'Fetches order status from external API',
          endpoint_url: 'https://api.example.com/orders/{{ order_id }}',
          http_method: 'POST',
          request_body_type: 'form_urlencoded',
          request_template: '{"order_id":"{{ order_id }}"}',
          enabled: true,
          param_schema: [
            { name: 'order_id', type: 'string', description: 'The order ID', required: true }
          ]
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: valid_attributes
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: valid_attributes,
             headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'creates a new custom tool and returns success status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: valid_attributes,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Fetch Order Status')
        expect(json_response[:description]).to eq('Fetches order status from external API')
        expect(json_response[:enabled]).to be(true)
        expect(json_response[:allow_file_artifacts]).to be(true)
        expect(json_response[:request_body_type]).to eq('form_urlencoded')
        expect(json_response[:slug]).to eq('custom_fetch_order_status')
        expect(json_response[:param_schema]).to eq([
                                                     {
                                                       name: 'order_id',
                                                       type: 'string',
                                                       description: 'The order ID',
                                                       required: true,
                                                       source: 'agent'
                                                     }
                                                   ])
      end

      it 'persists agent, system context, and fixed parameter sources' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: {
               custom_tool: {
                 title: 'Sync lead',
                 endpoint_url: 'https://api.example.com/leads',
                 http_method: 'POST',
                 param_schema: [
                   {
                     name: 'lead_name',
                     type: 'string',
                     description: 'Lead name',
                     source: 'agent'
                   },
                   {
                     name: 'customer_phone',
                     type: 'string',
                     description: 'Phone from system context',
                     source: 'context',
                     context_path: 'contact.phone_number',
                     required: true
                   },
                   {
                     name: 'filters',
                     type: 'object',
                     description: 'Static filters',
                     source: 'fixed',
                     fixed_value: '{"pipeline":"sales"}'
                   }
                 ]
               }
             },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:param_schema]).to eq([
                                                     {
                                                       name: 'lead_name',
                                                       type: 'string',
                                                       description: 'Lead name',
                                                       required: false,
                                                       source: 'agent'
                                                     },
                                                     {
                                                       name: 'customer_phone',
                                                       type: 'string',
                                                       description: 'Phone from system context',
                                                       required: true,
                                                       source: 'context',
                                                       context_path: 'contact.phone_number'
                                                     },
                                                     {
                                                       name: 'filters',
                                                       type: 'object',
                                                       description: 'Static filters',
                                                       required: false,
                                                       source: 'fixed',
                                                       fixed_value: '{"pipeline":"sales"}'
                                                     }
                                                   ])
      end

      it 'persists query and header destinations from the custom tool form' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: {
               custom_tool: {
                 title: 'Search leads',
                 endpoint_url: 'https://api.example.com/leads',
                 http_method: 'GET',
                 param_schema: [
                   {
                     name: 'search',
                     type: 'string',
                     description: 'Search text',
                     source: 'agent',
                     request_location: 'query',
                     request_key: 'q'
                   },
                   {
                     name: 'tenant_id',
                     type: 'string',
                     source: 'fixed',
                     fixed_value: 'tenant-42',
                     request_location: 'header',
                     request_key: 'X-Tenant-ID'
                   }
                 ]
               }
             },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:param_schema]).to include(
          include(request_location: 'query', request_key: 'q'),
          include(request_location: 'header', request_key: 'X-Tenant-ID')
        )
      end

      it 'defaults API key authentication to header mode when created from the modal payload shape' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: {
               custom_tool: {
                 title: 'Protected endpoint',
                 endpoint_url: 'https://api.example.com/protected',
                 http_method: 'GET',
                 auth_type: 'api_key',
                 auth_config: {
                   name: 'X-API-Key',
                   key: 'secret'
                 }
               }
             },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:auth_config]).to eq({
                                                    name: 'X-API-Key',
                                                    key: 'secret',
                                                    location: 'header'
                                                  })
      end

      context 'with invalid parameters' do
        let(:invalid_attributes) do
          {
            custom_tool: {
              title: '',
              endpoint_url: ''
            }
          }
        end

        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/custom_tools",
               params: invalid_attributes,
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'with invalid authentication config' do
        it 'returns unprocessable entity when bearer auth is missing a token' do
          post "/api/v1/accounts/#{account.id}/captain/custom_tools",
               params: {
                 custom_tool: {
                   title: 'Broken bearer tool',
                   endpoint_url: 'https://api.example.com/protected',
                   http_method: 'GET',
                   auth_type: 'bearer',
                   auth_config: {}
                 }
               },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include('bearer token is required')
        end
      end

      context 'with invalid endpoint URL' do
        let(:invalid_url_attributes) do
          {
            custom_tool: {
              title: 'Test Tool',
              endpoint_url: 'http://localhost/api',
              http_method: 'GET'
            }
          }
        end

        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/custom_tools",
               params: invalid_url_attributes,
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'with invalid Liquid template syntax' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/custom_tools",
               params: {
                 custom_tool: {
                   title: 'Broken template tool',
                   endpoint_url: 'https://api.example.com/orders/{{ order_id ',
                   http_method: 'GET'
                 }
               },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include('invalid Liquid syntax')
        end
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let(:custom_tool) { create(:captain_custom_tool, account: account) }
    let(:update_attributes) do
      {
        custom_tool: {
          title: 'Updated Tool Title',
          enabled: false,
          allow_file_artifacts: false
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: update_attributes
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: update_attributes,
              headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the custom tool and returns success status' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: update_attributes,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Updated Tool Title')
        expect(json_response[:enabled]).to be(false)
        expect(json_response[:allow_file_artifacts]).to be(false)
        expect(custom_tool.reload.allow_file_artifacts).to be(false)
      end

      it 'updates parameter sources without dropping context or fixed configuration' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: {
                custom_tool: {
                  param_schema: [
                    {
                      name: 'lead_name',
                      type: 'string',
                      description: 'Lead name',
                      source: 'agent'
                    },
                    {
                      name: 'customer_phone',
                      type: 'string',
                      description: 'Phone from system context',
                      source: 'context',
                      context_path: 'contact.phone_number',
                      required: true
                    },
                    {
                      name: 'pipeline',
                      type: 'string',
                      description: 'Static pipeline',
                      source: 'fixed',
                      fixed_value: 'sales'
                    }
                  ]
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:param_schema]).to eq([
                                                     {
                                                       name: 'lead_name',
                                                       type: 'string',
                                                       description: 'Lead name',
                                                       required: false,
                                                       source: 'agent'
                                                     },
                                                     {
                                                       name: 'customer_phone',
                                                       type: 'string',
                                                       description: 'Phone from system context',
                                                       required: true,
                                                       source: 'context',
                                                       context_path: 'contact.phone_number'
                                                     },
                                                     {
                                                       name: 'pipeline',
                                                       type: 'string',
                                                       description: 'Static pipeline',
                                                       required: false,
                                                       source: 'fixed',
                                                       fixed_value: 'sales'
                                                     }
                                                   ])
      end

      it 'defaults missing API key location to header on update as well' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: {
                custom_tool: {
                  auth_type: 'api_key',
                  auth_config: {
                    name: 'X-API-Key',
                    key: 'updated-secret'
                  }
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:auth_config]).to eq({
                                                    name: 'X-API-Key',
                                                    key: 'updated-secret',
                                                    location: 'header'
                                                  })
      end

      context 'with invalid parameters' do
        let(:invalid_attributes) do
          {
            custom_tool: {
              title: ''
            }
          }
        end

        it 'returns unprocessable entity status' do
          patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
                params: invalid_attributes,
                headers: admin.create_new_auth_token,
                as: :json

          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'with invalid authentication config' do
        it 'returns unprocessable entity when API key auth is missing the header name' do
          patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
                params: {
                  custom_tool: {
                    auth_type: 'api_key',
                    auth_config: {
                      key: 'secret'
                    }
                  }
                },
                headers: admin.create_new_auth_token,
                as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include('API key name is required')
        end
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/custom_tools/test' do
    let(:test_attributes) do
      {
        custom_tool: {
          title: 'Sync lead',
          description: 'Sends lead updates to an external system',
          endpoint_url: 'https://api.example.com/hooks/{{ manager_name }}/{{ pipeline }}?contact_id={{ customer_id }}',
          http_method: 'POST',
          request_template: '{"manager":"{{ manager_name }}","pipeline":"{{ pipeline }}","contact_id":{{ customer_id }},"phone":"{{ customer_phone }}"}',
          response_template: '{{ response.status }}',
          auth_type: 'none',
          auth_config: {},
          param_schema: [
            {
              name: 'manager_name',
              type: 'string',
              description: 'Manager selected by the agent',
              source: 'agent',
              required: true
            },
            {
              name: 'customer_id',
              type: 'number',
              description: 'Contact id from context',
              source: 'context',
              context_path: 'contact.id',
              required: true
            },
            {
              name: 'customer_phone',
              type: 'string',
              description: 'Phone number from context',
              source: 'context',
              context_path: 'contact.phone_number',
              required: true
            },
            {
              name: 'pipeline',
              type: 'string',
              description: 'Fixed pipeline',
              source: 'fixed',
              fixed_value: 'sales',
              required: true
            }
          ]
        },
        test_payload: {
          agent_params: {
            manager_name: 'alice'
          },
          context_values: {
            'contact.id': '42',
            'contact.phone_number': '+1234567890'
          }
        }
      }
    end

    before do
      allow(Resolv).to receive(:getaddresses).and_call_original
      allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'returns a preview without executing the outbound request' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.merge(preview_only: true),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:preview]).to eq({
                                                resolved_params: {
                                                  manager_name: 'alice',
                                                  customer_id: 42,
                                                  customer_phone: '+1234567890',
                                                  pipeline: 'sales'
                                                },
                                                url: 'https://api.example.com/hooks/alice/sales?contact_id=42',
                                                body: '{"manager":"alice","pipeline":"sales","contact_id":42,"phone":"+1234567890"}'
                                              })
        expect(WebMock).not_to have_requested(:post, /api\.example\.com/)
      end

      it 'redacts query API key values in preview payloads while using the raw URL for execution' do
        stub_request(:post, 'https://api.example.com/hooks/alice/sales?contact_id=42&api_key=secret')
          .with(body: '{"manager":"alice","pipeline":"sales","contact_id":42,"phone":"+1234567890"}')
          .to_return(status: 200, body: '{"status":"accepted"}', headers: { 'Content-Type' => 'application/json' })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.deep_merge(
               preview_only: false,
               custom_tool: {
                 auth_type: 'api_key',
                 auth_config: {
                   name: 'api_key',
                   key: 'secret',
                   location: 'query'
                 }
               }
             ),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:preview][:url]).to eq(
          'https://api.example.com/hooks/alice/sales?contact_id=42&api_key=REDACTED'
        )
        expect(WebMock).to have_requested(
          :post,
          'https://api.example.com/hooks/alice/sales?contact_id=42&api_key=secret'
        )
      end

      it 'executes the tool and returns preview plus response details' do
        stub_request(:post, 'https://api.example.com/hooks/alice/sales?contact_id=42')
          .with(body: '{"manager":"alice","pipeline":"sales","contact_id":42,"phone":"+1234567890"}')
          .to_return(status: 200, body: '{"status":"accepted"}', headers: { 'Content-Type' => 'application/json' })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.merge(preview_only: false),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:preview][:url]).to eq('https://api.example.com/hooks/alice/sales?contact_id=42')
        expect(json_response[:response]).to include(
          successful: true,
          status: 200,
          body: '{"status":"accepted"}',
          formatted_body: 'accepted'
        )
      end

      it 'loads only runtime preferences when executing a test request' do
        allow(Current).to receive(:account).and_return(account)
        expect(account).not_to receive(:captain_preferences)
        expect(account).to receive(:captain_runtime_preferences).and_call_original
        stub_request(:post, 'https://api.example.com/hooks/alice/sales?contact_id=42')
          .to_return(status: 200, body: '{"status":"accepted"}', headers: { 'Content-Type' => 'application/json' })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.merge(preview_only: false),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:response]).to include(successful: true, status: 200)
      end

      it 'returns non-successful downstream responses without dropping the preview' do
        stub_request(:post, 'https://api.example.com/hooks/alice/sales?contact_id=42')
          .with(body: '{"manager":"alice","pipeline":"sales","contact_id":42,"phone":"+1234567890"}')
          .to_return(status: 422, body: '{"error":"invalid manager"}', headers: { 'Content-Type' => 'application/json' })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.merge(preview_only: false),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:preview][:body]).to eq(
          '{"manager":"alice","pipeline":"sales","contact_id":42,"phone":"+1234567890"}'
        )
        expect(json_response[:response]).to include(
          successful: false,
          status: 422,
          body: '{"error":"invalid manager"}'
        )
        expect(json_response[:response][:format_error]).to include(
          'undefined variable status'
        )
      end

      it 'marks response template failures as non-successful even on HTTP 200' do
        stub_request(:post, 'https://api.example.com/hooks/alice/sales?contact_id=42')
          .with(body: '{"manager":"alice","pipeline":"sales","contact_id":42,"phone":"+1234567890"}')
          .to_return(status: 200, body: '{"error":"missing status"}', headers: { 'Content-Type' => 'application/json' })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.merge(preview_only: false),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:response]).to include(
          successful: false,
          status: 200,
          body: '{"error":"missing status"}'
        )
        expect(json_response[:response][:format_error]).to include(
          'undefined variable status'
        )
      end

      it 'returns a blocked preview response when tool arguments violate safety policy' do
        account.update!(captain_runtime: { 'assistant_safety_blocklist' => ['alice'] })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
             params: test_attributes.merge(preview_only: false),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:preview][:url]).to eq('https://api.example.com/hooks/alice/sales?contact_id=42')
        expect(json_response[:response]).to include(
          successful: false,
          blocked: true,
          stage: 'tool_arguments',
          reason: 'custom_blocklist',
          formatted_body: 'ERROR: Tool arguments blocked by safety policy'
        )
        expect(WebMock).not_to have_requested(:post, /api\.example\.com/)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let!(:custom_tool) { create(:captain_custom_tool, account: account) }

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        delete "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        delete "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
               headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'deletes the custom tool and returns no content status' do
        expect do
          delete "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
                 headers: admin.create_new_auth_token
        end.to change(Captain::CustomTool, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end

      context 'when custom tool does not exist' do
        it 'returns not found status' do
          delete "/api/v1/accounts/#{account.id}/captain/custom_tools/999999",
                 headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
