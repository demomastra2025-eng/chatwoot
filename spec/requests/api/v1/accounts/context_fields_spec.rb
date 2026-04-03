require 'rails_helper'

RSpec.describe 'Account Context Fields API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/context_fields" }
  let(:crm_role) do
    create(
      :custom_role,
      account: account,
      permissions: %w[crm_deal_view crm_task_view]
    )
  end

  before do
    account.enable_features!('crm_deals', 'crm_tasks', 'scheduling')

    create(
      :custom_attribute_definition,
      account: account,
      attribute_model: 'contact_attribute',
      attribute_key: 'vip-level.v2',
      attribute_display_name: 'VIP Level'
    )
    create(
      :custom_attribute_definition,
      account: account,
      attribute_model: 'conversation_attribute',
      attribute_key: 'order-id.v2',
      attribute_display_name: 'Order ID'
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'sales-region.v2',
      label: 'Sales Region'
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'follow-up-channel.v2',
      label: 'Follow Up Channel'
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit-room.v2',
      label: 'Visit Room'
    )
  end

  it 'returns only allowed scopes for a plain agent' do
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to include(
      hash_including(
        'id' => 'contact.name',
        'table_name' => 'contact'
      ),
      hash_including(
        'id' => 'contact.custom_attributes.vip-level.v2',
        'table_name' => 'contact',
        'field_type' => 'custom_attribute'
      ),
      hash_including(
        'id' => 'conversation.custom_attributes.order-id.v2',
        'table_name' => 'conversation',
        'field_type' => 'custom_attribute'
      ),
      hash_including(
        'id' => 'appointment.custom_attributes.visit-room.v2',
        'table_name' => 'appointment',
        'field_type' => 'custom_attribute'
      )
    )
    expect(response.parsed_body).not_to include(
      hash_including('table_name' => 'deal'),
      hash_including('table_name' => 'task')
    )
  end

  it 'returns CRM scopes when the user has CRM view permissions' do
    agent.account_users.find_by(account_id: account.id).update!(custom_role: crm_role)

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to include(
      hash_including(
        'id' => 'deal.custom_attributes.sales-region.v2',
        'table_name' => 'deal',
        'field_type' => 'custom_attribute'
      ),
      hash_including(
        'id' => 'task.custom_attributes.follow-up-channel.v2',
        'table_name' => 'task',
        'field_type' => 'custom_attribute'
      )
    )
  end
end
