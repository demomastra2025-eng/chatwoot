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
          http_method: 'GET',
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
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let(:custom_tool) { create(:captain_custom_tool, account: account) }
    let(:update_attributes) do
      {
        custom_tool: {
          title: 'Updated Tool Title',
          enabled: false
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
