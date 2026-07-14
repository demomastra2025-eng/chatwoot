require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::AutomationRulesController', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, inbox_id: inbox.id, contact_id: contact.id) }

  describe 'GET /api/v1/accounts/{account.id}/automation_rules' do
    context 'when it is an authenticated user' do
      it 'returns all records' do
        automation_rule = create(:automation_rule, account: account, name: 'Test Automation Rule')

        get "/api/v1/accounts/#{account.id}/automation_rules",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload].first[:id]).to eq(automation_rule.id)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/automation_rules"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/automation_rules' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/automation_rules"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:params) do
        {
          'name': 'Notify Conversation Created and mark priority query',
          'description': 'Notify all administrator about conversation created and mark priority query',
          'event_name': 'conversation_created',
          'conditions': [
            {
              'attribute_key': 'browser_language',
              'filter_operator': 'equal_to',
              'values': ['en'],
              'query_operator': 'AND'
            },
            {
              'attribute_key': 'country_code',
              'filter_operator': 'equal_to',
              'values': %w[USA UK],
              'query_operator': nil
            }
          ],
          'actions': [
            {
              'action_name': :send_message,
              'action_params': ['Welcome to the chatwoot platform.']
            },
            {
              'action_name': :assign_team,
              'action_params': [1]
            },
            {
              'action_name': :remove_assigned_agent
            },
            {
              'action_name': :remove_assigned_team
            },
            {
              'action_name': :add_label,
              'action_params': %w[support priority_customer]
            }
          ]
        }
      end

      it 'processes invalid query operator' do
        expect(account.automation_rules.count).to eq(0)
        params[:conditions] << {
          'attribute_key': 'browser_language',
          'filter_operator': 'equal_to',
          'values': ['en'],
          'query_operator': 'invalid'
        }

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_content)
        expect(account.automation_rules.count).to eq(0)
      end

      it 'throws an error for unknown attributes in condtions' do
        expect(account.automation_rules.count).to eq(0)
        params[:conditions] << {
          'attribute_key': 'unknown_attribute',
          'filter_operator': 'equal_to',
          'values': ['en'],
          'query_operator': 'AND'
        }

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_content)
        expect(account.automation_rules.count).to eq(0)
      end

      it 'rejects touch-plan application in a new automation rule' do
        touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
        params[:actions] = [
          { action_name: :apply_touch_plan, action_params: [touch_plan.id] }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_content)
        expect(account.automation_rules.count).to eq(0)
      end

      it 'Saves for automation_rules for account with country_code and browser_language conditions' do
        expect(account.automation_rules.count).to eq(0)

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'Saves for automation_rules for account with status conditions' do
        params[:conditions] = [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['resolved'],
            query_operator: nil
          }
        ]
        expect(account.automation_rules.count).to eq(0)

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'creates automation rules without attachments even when storage is over limit' do
        storage_service = instance_double(AccountLimits::StorageUsageService, within_limit?: false)
        allow(AccountLimits::StorageUsageService).to receive(:new).and_return(storage_service)

        params[:conditions] = [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['open'],
            query_operator: nil
          }
        ]
        params[:actions] = [
          {
            action_name: :assign_agent,
            action_params: [administrator.id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'saves appointment automation rules with managed custom field conditions' do
        account.enable_features!('scheduling')
        create(
          :crm_field_definition,
          account: account,
          entity_kind: 'appointment',
          key: 'visit_reason',
          label: 'Visit reason',
          field_type: 'select',
          options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
        )

        appointment_params = params.merge(
          event_name: 'appointment_created',
          conditions: [
            {
              attribute_key: 'visit_reason',
              filter_operator: 'equal_to',
              values: ['follow_up'],
              query_operator: nil,
              custom_attribute_type: 'appointment_attribute'
            }
          ],
          actions: [
            {
              action_name: :send_webhook_event,
              action_params: ['https://example.com/hooks/appointments']
            }
          ]
        )

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: appointment_params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
        expect(account.automation_rules.first.conditions.first['attribute_key']).to eq('visit_reason')
      end

      it 'saves appointment automation rules with native appointment actions' do
        account.enable_features!('scheduling')
        account.enable_features!('scheduling_finance')

        appointment_params = params.merge(
          event_name: 'appointment_updated',
          conditions: [
            {
              attribute_key: 'status',
              filter_operator: 'equal_to',
              values: ['scheduled'],
              query_operator: nil
            }
          ],
          actions: [
            {
              action_name: :change_appointment_status,
              action_params: ['confirmed']
            },
            {
              action_name: :cancel_appointment_payment,
              action_params: []
            }
          ]
        )

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: appointment_params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
        expect(account.automation_rules.first.actions.pluck('action_name')).to contain_exactly(
          'change_appointment_status',
          'cancel_appointment_payment'
        )
      end

      it 'saves deal automation rules with managed custom field conditions and native actions' do
        account.enable_features!('crm_deals')
        create(
          :crm_field_definition,
          account: account,
          entity_kind: 'deal',
          key: 'deal_region',
          label: 'Deal region',
          field_type: 'select',
          options: [{ 'label' => 'EMEA', 'value' => 'emea' }]
        )
        pipeline = create(:crm_pipeline, account: account)
        stage = create(:crm_stage, account: account, pipeline: pipeline)

        deal_params = params.merge(
          event_name: 'deal_created',
          conditions: [
            {
              attribute_key: 'deal_region',
              filter_operator: 'equal_to',
              values: ['emea'],
              query_operator: nil,
              custom_attribute_type: 'deal_attribute'
            }
          ],
          actions: [
            {
              action_name: :change_deal_stage,
              action_params: [stage.id]
            }
          ]
        )

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: deal_params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
        expect(account.automation_rules.first.event_name).to eq('deal_created')
        expect(account.automation_rules.first.conditions.first['attribute_key']).to eq('deal_region')
        expect(account.automation_rules.first.actions.first['action_name']).to eq('change_deal_stage')
      end

      it 'saves deal automation rules when referenced stages are active' do
        account.enable_features!('crm_deals')
        pipeline = create(:crm_pipeline, account: account)
        source_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#F0F0F3')
        target_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#E8E8EC')

        deal_params = params.merge(
          event_name: 'deal_updated',
          conditions: [
            {
              attribute_key: 'stage_id',
              filter_operator: 'equal_to',
              values: [source_stage.id],
              query_operator: nil
            }
          ],
          actions: [
            {
              action_name: :change_deal_stage,
              action_params: [target_stage.id]
            }
          ]
        )

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: deal_params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'rejects deal automation rules with archived stage conditions with field context' do
        account.enable_features!('crm_deals')
        pipeline = create(:crm_pipeline, account: account)
        archived_stage = create(:crm_stage, account: account, pipeline: pipeline, active: false, color: '#F0F0F3')
        target_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#E8E8EC')

        deal_params = params.merge(
          event_name: 'deal_updated',
          conditions: [
            {
              attribute_key: 'stage_id',
              filter_operator: 'equal_to',
              values: [archived_stage.id],
              query_operator: nil
            }
          ],
          actions: [
            {
              action_name: :change_deal_stage,
              action_params: [target_stage.id]
            }
          ]
        )

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: deal_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(account.automation_rules.count).to eq(0)
        expect(response.parsed_body['errors']).to include(
          a_hash_including(
            'field' => 'conditions',
            'path' => 'conditions[0].values[0]',
            'code' => 'ARCHIVED_OR_DELETED_STAGE_REFERENCE',
            'message' => 'Referenced follow-up stage is archived or deleted. Select an active stage before saving this automation.'
          )
        )
      end

      it 'saves task automation rules with managed custom field conditions and native actions' do
        account.enable_features!('crm_tasks')
        create(
          :crm_field_definition,
          account: account,
          entity_kind: 'task',
          key: 'task_channel',
          label: 'Task channel',
          field_type: 'select',
          options: [{ 'label' => 'Chat', 'value' => 'chat' }]
        )
        task_status = create(:crm_task_status, account: account)

        task_params = params.merge(
          event_name: 'task_created',
          conditions: [
            {
              attribute_key: 'task_channel',
              filter_operator: 'equal_to',
              values: ['chat'],
              query_operator: nil,
              custom_attribute_type: 'task_attribute'
            }
          ],
          actions: [
            {
              action_name: :change_task_status,
              action_params: [task_status.id]
            }
          ]
        )

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: task_params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
        expect(account.automation_rules.first.event_name).to eq('task_created')
        expect(account.automation_rules.first.conditions.first['attribute_key']).to eq('task_channel')
        expect(account.automation_rules.first.actions.first['action_name']).to eq('change_task_status')
      end

      it 'Saves file in the automation actions to send an attachments' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        expect(account.automation_rules.count).to eq(0)

        params[:actions] = [
          {
            'action_name': :send_message,
            'action_params': ['Welcome to the chatwoot platform.']
          },
          {
            'action_name': :send_attachment,
            'action_params': [blob.signed_id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        automation_rule = account.automation_rules.first
        expect(automation_rule.files.presence).to be_truthy
        expect(automation_rule.files.count).to eq(1)
      end

      it 'Saves files in the automation actions to send multiple attachments' do
        blob_1 = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )
        blob_2 = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/sample.png').open,
          filename: 'sample.png',
          content_type: 'image/png'
        )

        params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob_1.signed_id]
          },
          {
            'action_name': :send_attachment,
            'action_params': [blob_2.signed_id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        automation_rule = account.automation_rules.first
        expect(automation_rule.files.count).to eq(2)
      end

      it 'returns error for invalid attachment blob_id' do
        params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': ['invalid_blob_id']
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq(
          I18n.t('errors.attachments.invalid', locale: :en)
        )
      end

      it 'stores the original blob_id in action_params after create' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob.signed_id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        automation_rule = account.automation_rules.first
        attachment_action = automation_rule.actions.find { |a| a['action_name'] == 'send_attachment' }
        expect(attachment_action['action_params'].first).to be_a(Integer)
        expect(attachment_action['action_params'].first).to eq(automation_rule.files.first.blob_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns for automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)

        get "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload]).to be_present
        expect(body[:payload][:id]).to eq(automation_rule.id)
      end

      it 'returns not found instead of rendering a nil automation rule' do
        get "/api/v1/accounts/#{account.id}/automation_rules/999999",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to include('error' => 'Resource could not be found')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}/clone' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns for cloned automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)

        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone",
             headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload]).to be_present
        expect(body[:payload][:id]).not_to eq(automation_rule.id)
        expect(account.automation_rules.count).to eq(2)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:update_params) do
        {
          'description': 'Update description',
          'name': 'Update name',
          'conditions': [
            {
              'attribute_key': 'browser_language',
              'filter_operator': 'equal_to',
              'values': ['en'],
              'query_operator': 'AND'
            }
          ],
          'actions': [
            {
              'action_name': :add_label,
              'action_params': %w[support priority_customer]
            }
          ]
        }
      end

      it 'returns for cloned automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)
        expect(account.automation_rules.first.actions.size).to eq(4)

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload][:name]).to eq('Update name')
        expect(body[:payload][:description]).to eq('Update description')
        expect(body[:payload][:conditions].size).to eq(1)
        expect(body[:payload][:actions].size).to eq(1)
      end

      it 'returns for updated active flag for automation_rule' do
        expect(automation_rule.active).to be(true)
        params = { active: false }

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: params

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload][:active]).to be(false)
        expect(automation_rule.reload.active).to be(false)
      end

      it 'allows deactivating a deal automation rule with stale stage references' do
        account.enable_features!('crm_deals')
        pipeline = create(:crm_pipeline, account: account)
        source_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#F0F0F3')
        target_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#E8E8EC')
        automation_rule.update!(
          event_name: 'deal_updated',
          conditions: [
            {
              attribute_key: 'stage_id',
              filter_operator: 'equal_to',
              values: [source_stage.id],
              query_operator: nil
            }
          ],
          actions: [
            {
              action_name: :change_deal_stage,
              action_params: [target_stage.id]
            }
          ]
        )
        target_stage.update!(active: false)

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: { active: false }

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'active')).to be(false)
        expect(automation_rule.reload).not_to be_active
      end

      it 'rejects activating a deal automation rule with stale stage references' do
        account.enable_features!('crm_deals')
        pipeline = create(:crm_pipeline, account: account)
        create(:crm_stage, account: account, pipeline: pipeline, color: '#F0F0F3')
        target_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#E8E8EC')
        automation_rule.update!(
          active: false,
          event_name: 'deal_updated',
          conditions: [
            {
              attribute_key: 'stage_id',
              filter_operator: 'is_present',
              values: [],
              query_operator: nil
            }
          ],
          actions: [
            {
              action_name: :change_deal_stage,
              action_params: [target_stage.id]
            }
          ]
        )
        target_stage.update!(active: false)

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: { active: true }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['errors']).to include(
          a_hash_including(
            'field' => 'actions',
            'path' => 'actions[0].action_params[0]',
            'code' => 'ARCHIVED_OR_DELETED_STAGE_REFERENCE'
          )
        )
        expect(automation_rule.reload).not_to be_active
      end

      it 'allows update with existing blob_id' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        automation_rule.update!(actions: [{ 'action_name' => 'send_attachment', 'action_params' => [blob.id] }])
        automation_rule.files.attach(blob)

        update_params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob.id]
          }
        ]

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:success)
      end

      it 'returns error for invalid blob_id on update' do
        update_params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [999_999]
          }
        ]

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq(
          I18n.t('errors.attachments.invalid', locale: :en)
        )
      end

      it 'allows adding new attachment on update with signed blob_id' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        update_params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob.signed_id]
          }
        ]

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:success)
        expect(automation_rule.reload.files.count).to eq(1)
      end

      it 'rejects update with deleted stage action references with field context' do
        account.enable_features!('crm_deals')
        pipeline = create(:crm_pipeline, account: account)
        deleted_stage = create(:crm_stage, account: account, pipeline: pipeline)
        deleted_stage.destroy!

        update_params.merge!(
          event_name: 'deal_updated',
          conditions: [
            {
              attribute_key: 'stage_id',
              filter_operator: 'is_present',
              values: [],
              query_operator: nil
            }
          ],
          actions: [
            {
              action_name: :change_deal_stage,
              action_params: [deleted_stage.id]
            }
          ]
        )

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['errors']).to include(
          a_hash_including(
            'field' => 'actions',
            'path' => 'actions[0].action_params[0]',
            'code' => 'ARCHIVED_OR_DELETED_STAGE_REFERENCE',
            'message' => 'Referenced follow-up stage is archived or deleted. Select an active stage before saving this automation.'
          )
        )
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'delete the automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)

        delete "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(0)
      end
    end
  end
end
