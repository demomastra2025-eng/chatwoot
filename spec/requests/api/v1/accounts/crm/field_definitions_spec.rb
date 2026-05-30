require 'rails_helper'

RSpec.describe 'CRM Field Definitions API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/field_definitions" }

  before do
    account.enable_features!('crm_deals')
  end

  it 'creates a field definition for deal custom fields' do
    post path,
         params: {
           entity_kind: 'deal',
           key: 'lead_source_code',
           label: 'Lead source',
           field_type: 'text',
           active: true
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'key')).to eq('lead_source_code')
  end

  it 'creates a field definition for appointment custom fields when scheduling is enabled' do
    account.disable_features!('crm_deals')
    account.enable_features!('scheduling')

    post path,
         params: {
           entity_kind: 'appointment',
           key: 'visit_reason',
           label: 'Visit reason',
           field_type: 'text',
           active: true
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'entity_kind')).to eq('appointment')
    expect(response.parsed_body.dig('payload', 'key')).to eq('visit_reason')
  end

  it 'creates a field definition at the end for the entity kind when position is omitted' do
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'deal_size', position: 0)
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'lead_temperature', position: 1)

    post path,
         params: {
           entity_kind: 'deal',
           key: 'budget_band',
           label: 'Budget band',
           field_type: 'text',
           active: true
         },
         headers: headers,
         as: :json

    created_definition = account.crm_field_definitions.find_by!(key: 'budget_band')

    expect(response).to have_http_status(:created)
    expect(created_definition.position).to eq(2)
    expect(account.crm_field_definitions.for_entity_kind('deal').ordered.last.id).to eq(created_definition.id)
  end

  it 'rejects keys that conflict with built-in fields' do
    post path,
         params: {
           entity_kind: 'deal',
           key: 'pipeline_id',
           label: 'Pipeline',
           field_type: 'text'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig('details', 'key')).to include('Key conflicts with a built-in field')
  end

  it 'rejects appointment keys that conflict with built-in fields' do
    account.disable_features!('crm_deals')
    account.enable_features!('scheduling')

    post path,
         params: {
           entity_kind: 'appointment',
           key: 'starts_at',
           label: 'Starts at',
           field_type: 'datetime'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig('details', 'key')).to include('Key conflicts with a built-in field')
  end

  it 'removes deleted appointment field values from existing appointments without touching unmanaged keys' do
    account.disable_features!('crm_deals')
    account.enable_features!('scheduling')

    field_definition = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'text'
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: create(:scheduling_resource, account: account),
      service: create(:scheduling_service, account: account),
      contact: create(:contact, account: account),
      custom_attributes: {
        'visit_reason' => 'follow up',
        'legacy_key' => 'keep me'
      }
    )

    delete "#{path}/#{field_definition.id}", headers: headers, as: :json

    expect(response).to have_http_status(:no_content)
    expect(appointment.reload.custom_attributes).to eq(
      {
        'legacy_key' => 'keep me'
      }
    )
  end

  it 'filters definitions by entity_kind' do
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'deal_field')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'task_field')
    account.enable_features!('crm_tasks')

    get path, params: { entity_kind: 'deal' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'entity_kind')).to eq('deal')
  end

  it 'allows plain agents to read CRM field definitions for enabled runtime features' do
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'deal_field')

    get path, params: { entity_kind: 'deal' }, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'key')).to eq('deal_field')
  end

  it 'rejects plain agents from configuring CRM field definitions' do
    post path,
         params: {
           entity_kind: 'deal',
           key: 'lead_source_code',
           label: 'Lead source',
           field_type: 'text',
           active: true
         },
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(account.crm_field_definitions.where(key: 'lead_source_code')).not_to exist
  end

  it 'marks the deal source field as system in API payloads' do
    source_field = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'source',
      label: 'Источник',
      field_type: 'select',
      options: [{ label: 'Вручную', value: 'manual' }]
    )

    get path, params: { entity_kind: 'deal' }, headers: headers, as: :json

    payload = response.parsed_body.fetch('payload').find { |item| item['id'] == source_field.id }
    expect(response).to have_http_status(:ok)
    expect(payload['system']).to be(true)
  end

  it 'allows editable attributes of the system deal source field' do
    source_field = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'source',
      label: 'Источник',
      field_type: 'select',
      options: [{ label: 'Вручную', value: 'manual' }]
    )

    patch "#{path}/#{source_field.id}",
          params: {
            label: 'Канал источника',
            active: false,
            default_value: 'website',
            position: 7,
            options: [{ label: 'Сайт', value: 'website' }]
          },
          headers: headers,
          as: :json

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload).to include(
      'key' => 'source',
      'field_type' => 'select',
      'label' => 'Канал источника',
      'active' => false,
      'default_value' => 'website',
      'position' => 7,
      'system' => true
    )
    expect(payload['options']).to eq([{ 'label' => 'Сайт', 'value' => 'website' }])
  end

  it 'rejects key and type changes for the system deal source field' do
    source_field = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'source',
      label: 'Источник',
      field_type: 'select',
      options: [{ label: 'Вручную', value: 'manual' }]
    )

    patch "#{path}/#{source_field.id}",
          params: {
            key: 'origin',
            field_type: 'text',
            label: 'Origin'
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('SYSTEM_FIELD_LOCKED')
    expect(source_field.reload).to have_attributes(key: 'source', field_type: 'select')
  end

  it 'rejects deleting the system deal source field' do
    source_field = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'source',
      label: 'Источник',
      field_type: 'select',
      options: [{ label: 'Вручную', value: 'manual' }]
    )

    delete "#{path}/#{source_field.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('SYSTEM_FIELD_LOCKED')
    expect(account.crm_field_definitions.where(id: source_field.id)).to exist
  end

  it 'returns forbidden when neither crm_deals nor crm_tasks is enabled' do
    account.disable_features!('crm_deals')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end
end
