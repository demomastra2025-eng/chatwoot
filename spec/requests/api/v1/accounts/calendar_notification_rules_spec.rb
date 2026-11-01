require 'rails_helper'

RSpec.describe 'Calendar appointment notification rules', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/automation_rules" }
  let(:rule_params) do
    {
      name: 'Visit message', event_name: 'appointment_created', active: false, calendar_managed: true,
      conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
      actions: [{ action_name: 'create_touch', action_params: [{
        action_type: 'send_message', content_kind: 'free_text', body: 'Your visit is scheduled',
        timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: 0,
        target_inbox_id: create(:inbox, account: account).id
      }] }]
    }
  end

  it 'marks the rule and prevents editing it through the generic automation form' do
    post path, params: rule_params, headers: headers
    expect(response).to have_http_status(:success)
    rule = account.automation_rules.last
    expect(rule).to be_calendar_managed
    expect(rule.actions.first['action_params'].first['relative_offset_seconds'].to_i).to eq(0)

    put "#{path}/#{rule.id}", params: { active: true }, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(rule.reload).not_to be_active

    put "#{path}/#{rule.id}", params: { active: true, calendar_context: true }, headers: headers
    expect(response).to have_http_status(:success)
    expect(rule.reload).to be_active
  end

  it 'returns an account-scoped appointment notification summary' do
    appointment = create(
      :scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account)
    )
    reminder = create(:reminder, account: account, remindable: appointment)
    get "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/notifications", headers: headers

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['payload']).to include(include('id' => reminder.id, 'status' => 'draft'))
  end

  it 'includes the rule name and existing message link in the appointment summary' do
    appointment = create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account))
    conversation = create(:conversation, account: account)
    message = create(:message, account: account, conversation: conversation)
    rule = create(:automation_rule, account: account, name: 'Visit notice')
    reminder = create(:reminder, account: account, remindable: appointment)
    reminder.mark_automation_provenance!(rule)
    reminder.mark_delivery_materialized!(message.id)

    get "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/notifications", headers: headers

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['payload']).to include(include('rule_name' => 'Visit notice', 'message_id' => message.id,
                                                               'conversation_id' => conversation.id, 'message_status' => 'sent'))
  end

  it 'adopts one valid legacy rule without changing its id, state, conditions, actions or send plan' do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false,
                                        validate_provider_config: false)
    channel.update!(message_templates: [{ 'name' => 'visit_notice', 'language' => 'ru', 'status' => 'APPROVED' }])
    conditions = [{ attribute_key: 'source', filter_operator: 'equal_to', values: ['manual'], query_operator: nil }]
    actions = [{ action_name: 'create_touch', action_params: [{
      action_type: 'send_message', content_kind: 'channel_template',
      template_params: { name: 'visit_notice', language: 'ru' },
      timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: -3600,
      repeat_mode: 'once', target_inbox_id: channel.inbox.id
    }] }, { action_name: 'create_touch', action_params: [{
      action_type: 'send_message', content_kind: 'channel_template',
      template_params: { name: 'visit_notice', language: 'ru' },
      timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: -7200,
      repeat_mode: 'once', target_inbox_id: channel.inbox.id
    }] }]
    rule = create(:automation_rule, account: account, event_name: 'appointment_created', active: false,
                                    conditions: conditions, actions: actions)
    original = rule.reload.attributes.slice('id', 'active', 'conditions', 'actions')

    post "#{path}/#{rule.id}/adopt_calendar_notification", headers: headers

    expect(response).to have_http_status(:ok)
    expect(rule.reload).to be_calendar_managed
    expect(rule.attributes.slice('id', 'active', 'conditions', 'actions')).to eq(original)
  end

  it 'rejects a legacy rule whose template is still on Meta review' do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false,
                                        validate_provider_config: false)
    channel.update!(message_templates: [{ 'name' => 'visit_notice', 'language' => 'ru', 'status' => 'PENDING' }])
    rule = create(:automation_rule, account: account, event_name: 'appointment_created', active: false,
                                    conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                                    actions: [{ action_name: 'create_touch', action_params: [{
                                      action_type: 'send_message', content_kind: 'channel_template',
                                      template_params: { name: 'visit_notice', language: 'ru' },
                                      timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 0,
                                      repeat_mode: 'once', target_inbox_id: channel.inbox.id
                                    }] }])

    post "#{path}/#{rule.id}/adopt_calendar_notification", headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(rule.reload).not_to be_calendar_managed
  end

  it 'round-trips creating, partial-updating, updating, cloning and clearing min_minutes_before_appointment' do
    post path, params: rule_params.merge(min_minutes_before_appointment: 60), headers: headers
    expect(response).to have_http_status(:success)
    rule_id = response.parsed_body.dig('payload', 'id') || account.automation_rules.last.id
    expect(response.parsed_body.dig('payload', 'min_minutes_before_appointment') || response.parsed_body['min_minutes_before_appointment']).to eq(60)

    put "#{path}/#{rule_id}", params: { active: true, calendar_context: true }, headers: headers
    expect(response).to have_http_status(:success)
    expect(account.automation_rules.find(rule_id).min_minutes_before_appointment).to eq(60)

    put "#{path}/#{rule_id}", params: { min_minutes_before_appointment: 120, calendar_context: true }, headers: headers
    expect(response).to have_http_status(:success)
    expect(account.automation_rules.find(rule_id).min_minutes_before_appointment).to eq(120)

    put "#{path}/#{rule_id}", params: { min_minutes_before_appointment: '', calendar_context: true }, headers: headers
    expect(account.automation_rules.find(rule_id).min_minutes_before_appointment).to be_nil
  end

  it 'preserves min_minutes_before_appointment on clone and rejects invalid values via API' do
    rule = create(:automation_rule, account: account, event_name: 'appointment_created', active: false,
                                    min_minutes_before_appointment: 60,
                                    conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                                    actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hook'] }])

    post "#{path}/#{rule.id}/clone", headers: headers
    expect(response).to have_http_status(:success)
    expect(account.automation_rules.order(:id).last.min_minutes_before_appointment).to eq(60)

    put "#{path}/#{rule.id}", params: { min_minutes_before_appointment: 0 }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['errors']).to include(include('field' => 'min_minutes_before_appointment'))
  end

  it 'updates and clears min_minutes_before_appointment via generic automation editor payload without top-level field' do
    inbox = create(:inbox, account: account)
    touch_param = {
      action_type: 'send_message', content_kind: 'free_text', body: 'Booked',
      timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 0,
      target_inbox_id: inbox.id, min_minutes_before_appointment: 60
    }
    rule = create(:automation_rule, account: account, event_name: 'appointment_created', calendar_managed: false,
                                    min_minutes_before_appointment: 60,
                                    conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                                    actions: [{ action_name: 'create_touch', action_params: [touch_param] }])

    put "#{path}/#{rule.id}",
        params: { name: rule.name, event_name: 'appointment_created', conditions: rule.conditions,
                  actions: [{ action_name: 'create_touch', action_params: [touch_param.merge(min_minutes_before_appointment: 90)] }] },
        headers: headers
    expect(response).to have_http_status(:success)
    expect(rule.reload.min_minutes_before_appointment).to eq(90)

    put "#{path}/#{rule.id}",
        params: { name: rule.name, event_name: 'appointment_created', conditions: rule.conditions,
                  actions: [{ action_name: 'create_touch', action_params: [touch_param.except(:min_minutes_before_appointment)] }] },
        headers: headers
    expect(response).to have_http_status(:success)
    expect(rule.reload.min_minutes_before_appointment).to be_nil
    expect(rule.execution_schedule).not_to have_key('min_minutes_before_appointment')
  end

  it 'strips min_minutes_before_appointment when switching to cancellation or conversation events and rejects explicit post-visit values' do
    inbox = create(:inbox, account: account)
    touch_param = {
      action_type: 'send_message', content_kind: 'free_text', body: 'Notice',
      timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 0,
      target_inbox_id: inbox.id, min_minutes_before_appointment: 60
    }
    rule = create(:automation_rule, account: account, event_name: 'appointment_created', calendar_managed: false,
                                    min_minutes_before_appointment: 60,
                                    conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                                    actions: [{ action_name: 'create_touch', action_params: [touch_param] }])

    put "#{path}/#{rule.id}",
        params: { name: rule.name, event_name: 'appointment_cancelled', conditions: rule.conditions,
                  actions: [{ action_name: 'create_touch', action_params: [touch_param] }] },
        headers: headers
    expect(response).to have_http_status(:success)
    expect(rule.reload.min_minutes_before_appointment).to be_nil
    expect(rule.actions.first['action_params'].first).not_to have_key('min_minutes_before_appointment')

    put "#{path}/#{rule.id}", params: { min_minutes_before_appointment: 60 }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)

    put "#{path}/#{rule.id}",
        params: { name: rule.name, event_name: 'conversation_created',
                  conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }],
                  actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hook'] }] },
        headers: headers
    expect(response).to have_http_status(:success)
  end

  it 'updates min_minutes_before_appointment from calendar_context without flipping custom rules to calendar_managed' do
    inbox = create(:inbox, account: account)
    rule = create(:automation_rule, account: account, event_name: 'appointment_created', calendar_managed: false,
                                    conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                                    actions: [{ action_name: 'create_touch', action_params: [{
                                      action_type: 'send_message', content_kind: 'free_text', body: 'Custom booked',
                                      timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 0,
                                      target_inbox_id: inbox.id
                                    }] }])

    put "#{path}/#{rule.id}", params: { min_minutes_before_appointment: 75, calendar_context: true }, headers: headers
    expect(response).to have_http_status(:success)
    expect(rule.reload.min_minutes_before_appointment).to eq(75)
    expect(rule).not_to be_calendar_managed

    put "#{path}/#{rule.id}", params: { name: 'Still editable in Automations' }, headers: headers
    expect(response).to have_http_status(:success)
  end
end
