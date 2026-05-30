require 'rails_helper'

RSpec.describe 'Custom Attribute Definitions API', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/{account.id}/custom_attribute_definitions' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let!(:custom_attribute_definition) { create(:custom_attribute_definition, account: account) }

      it 'returns all customer attribute definitions related to the account' do
        create(:custom_attribute_definition, attribute_model: 'contact_attribute', account: account)

        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
            headers: user.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body

        expect(response_body.count).to eq(2)
        expect(response_body.first['attribute_key']).to eq(custom_attribute_definition.attribute_key)
      end

      it 'allows agents to read attribute definitions' do
        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
      end

      it 'allows custom-role users with runtime permissions to read attribute definitions' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
        custom_role_user = create(:user, account: account, role: :agent)
        custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
            headers: custom_role_user.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
      end

      it 'rejects custom-role users without runtime permissions from reading attribute definitions' do
        custom_role = create(:custom_role, account: account, permissions: [])
        custom_role_user = create(:user, account: account, role: :agent)
        custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
            headers: custom_role_user.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/custom_attribute_definitions/:id' do
    let!(:custom_attribute_definition) { create(:custom_attribute_definition, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'shows the custom attribute definition' do
        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
            headers: user.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include(custom_attribute_definition.attribute_key)
      end

      it 'allows agents to show custom attribute definitions' do
        get "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/custom_attribute_definitions' do
    let(:payload) do
      {
        custom_attribute_definition: {
          attribute_display_name: 'Developer ID',
          attribute_key: 'developer_id',
          attribute_model: 'contact_attribute',
          attribute_display_type: 'text',
          default_value: ''
        }
      }
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        expect do
          post "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
               params: payload
        end.not_to change(CustomAttributeDefinition, :count)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'creates the filter' do
        expect do
          post "/api/v1/accounts/#{account.id}/custom_attribute_definitions", headers: user.create_new_auth_token,
                                                                              params: payload
        end.to change(CustomAttributeDefinition, :count).by(1)

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['attribute_key']).to eq 'developer_id'
      end

      it 'does not allow agents to create definitions' do
        expect do
          post "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
               headers: agent.create_new_auth_token,
               params: payload
        end.not_to change(CustomAttributeDefinition, :count)

        expect(response).to have_http_status(:unauthorized)
      end

      context 'when creating with a conflicting attribute_key' do
        let(:standard_key) { CustomAttributeDefinition::STANDARD_ATTRIBUTES[:conversation].first }
        let(:conflicting_payload) do
          {
            custom_attribute_definition: {
              attribute_display_name: 'Conflicting Key',
              attribute_key: standard_key,
              attribute_model: 'conversation_attribute',
              attribute_display_type: 'text'
            }
          }
        end

        it 'returns error for conflicting key' do
          post "/api/v1/accounts/#{account.id}/custom_attribute_definitions",
               headers: user.create_new_auth_token,
               params: conflicting_payload

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['message']).to include('The provided key is not allowed as it might conflict with default attributes.')
        end
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/custom_attribute_definitions/:id' do
    let(:payload) { { custom_attribute_definition: { attribute_display_name: 'Developer ID', attribute_key: 'developer_id' } } }
    let!(:custom_attribute_definition) { create(:custom_attribute_definition, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
            params: payload

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'updates the custom attribute definition' do
        patch "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
              headers: user.create_new_auth_token,
              params: payload,
              as: :json
        expect(response).to have_http_status(:success)
        expect(custom_attribute_definition.reload.attribute_display_name).to eq('Developer ID')
        expect(custom_attribute_definition.reload.attribute_key).to eq('developer_id')
        expect(custom_attribute_definition.reload.attribute_model).to eq('conversation_attribute')
      end

      it 'does not allow agents to update definitions' do
        patch "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
              headers: agent.create_new_auth_token,
              params: payload,
              as: :json

        expect(response).to have_http_status(:unauthorized)
        expect(custom_attribute_definition.reload.attribute_display_name).not_to eq('Developer ID')
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/custom_attribute_definitions/:id' do
    let!(:custom_attribute_definition) { create(:custom_attribute_definition, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated admin user' do
      it 'deletes custom attribute' do
        delete "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
               headers: user.create_new_auth_token,
               as: :json
        expect(response).to have_http_status(:no_content)
        expect(account.custom_attribute_definitions.count).to be 0
      end

      it 'does not allow agents to delete definitions' do
        delete "/api/v1/accounts/#{account.id}/custom_attribute_definitions/#{custom_attribute_definition.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
        expect(custom_attribute_definition.reload).to be_present
      end
    end
  end
end
