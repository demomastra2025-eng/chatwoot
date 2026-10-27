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
end
