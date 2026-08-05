require 'rails_helper'

RSpec.describe 'Touches API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:conversation) { create(:conversation, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/touches" }

  it 'lists touches for the account' do
    create(:reminder, account: account, touch_conversation: conversation, body: 'First touch')
    create(:reminder, account: account, touch_conversation: conversation, body: 'Second touch')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(2)
    expect(response.parsed_body.dig('payload', 0, 'action_type')).to eq('send_message')
  end

  it 'lists a requested page with pagination metadata' do
    3.times do |index|
      create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        body: "Touch #{index}"
      )
    end

    get path, params: { page: 2, per_page: 2 }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].size).to eq(1)
    expect(response.parsed_body['meta']).to include(
      'count' => 3,
      'current_page' => 2,
      'per_page' => 2,
      'total_pages' => 2
    )
  end

  it 'returns an empty list for unsupported remindable filters' do
    create(:reminder, account: account, touch_conversation: conversation)

    get path,
        params: {
          remindable_type: 'String',
          remindable_id: '1'
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(0)
  end

  it 'creates a touch' do
    post path,
         params: {
           remindable_type: 'Conversation',
           remindable_id: conversation.id,
           conversation_id: conversation.id,
           target_inbox_id: conversation.inbox_id,
           target_contact_id: conversation.contact_id,
           target_contact_inbox_id: conversation.contact_inbox_id,
           scheduled_at: 1.hour.from_now.iso8601,
           repeat_mode: 'weekly',
           repeat_until_at: 1.month.from_now.iso8601,
           timezone: 'UTC',
           body: 'Follow up {{contact.name}} tomorrow'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'status')).to eq('pending')
    expect(response.parsed_body.dig('payload', 'repeat_mode')).to eq('weekly')
    expect(response.parsed_body.dig('payload', 'text_mode')).to eq('dynamic')
    expect(account.reminders.count).to eq(1)
  end

  describe 'appointment confirmation template validation' do
    let(:confirmation_channel) do
      create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
    end
    let(:confirmation_conversation) do
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: confirmation_channel.inbox)
      create(
        :conversation,
        account: account,
        inbox: confirmation_channel.inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
    end
    let(:appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: confirmation_conversation.contact,
        conversation: confirmation_conversation,
        starts_at: 2.hours.from_now,
        ends_at: 3.hours.from_now
      )
    end
    let(:valid_template) do
      {
        'name' => 'appointment_confirmation',
        'language' => 'ru',
        'status' => 'APPROVED',
        'components' => [
          { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
          { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }] }
        ]
      }
    end
    let(:invalid_template) do
      valid_template.deep_dup.tap do |template|
        template['name'] = 'appointment_confirmation_multiple'
        template['components'].last['buttons'] << { 'type' => 'QUICK_REPLY', 'text' => 'Перенести' }
      end
    end

    before do
      confirmation_channel.update!(message_templates: [valid_template, invalid_template])
    end

    it 'rejects direct API creation when the template has multiple buttons' do
      post path,
           params: confirmation_touch_params(invalid_template['name']),
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(account.reminders).to be_empty
    end

    it 'rejects direct API updates to a template with multiple buttons' do
      post path,
           params: confirmation_touch_params(valid_template['name']),
           headers: headers,
           as: :json
      touch = account.reminders.sole

      patch "#{path}/#{touch.id}",
            params: { template_params: { name: invalid_template['name'], language: 'ru' } },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(touch.reload.template_params).to include('name' => valid_template['name'])
    end

    def confirmation_touch_params(template_name)
      {
        remindable_type: 'Scheduling::Appointment',
        remindable_id: appointment.id,
        conversation_id: confirmation_conversation.display_id,
        target_conversation_id: confirmation_conversation.display_id,
        target_inbox_id: confirmation_channel.inbox.id,
        target_contact_id: confirmation_conversation.contact_id,
        target_contact_inbox_id: confirmation_conversation.contact_inbox_id,
        content_kind: 'channel_template',
        template_params: { name: template_name, language: 'ru' },
        response_action: 'confirm_appointment',
        response_button_index: 0,
        repeat_mode: 'once',
        scheduled_at: 1.hour.from_now.iso8601,
        timezone: 'UTC'
      }
    end
  end

  it 'round-trips a conversation post-delivery action' do
    forged_rule = create(:automation_rule, account: account)

    post path,
         params: {
           remindable_type: 'Conversation',
           remindable_id: conversation.id,
           conversation_id: conversation.id,
           target_conversation_id: conversation.id,
           target_inbox_id: conversation.inbox_id,
           scheduled_at: 1.hour.from_now.iso8601,
           repeat_mode: 'once',
           timezone: 'UTC',
           body: 'Final follow-up',
           post_delivery_action: 'resolve_conversation',
           metadata: {
             visible: 'kept',
             automation_rule_id: forged_rule.id,
             touch_source: 'automation',
             post_delivery_automation_rule_id: forged_rule.id,
             post_delivery_audit_source: 'automation'
           }
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'post_delivery_action')).to eq('resolve_conversation')
    touch = account.reminders.sole
    expect(touch.post_delivery_action).to eq('resolve_conversation')
    expect(touch.creator).to eq(administrator)
    expect(touch.metadata).to include(
      'visible' => 'kept',
      'automation_rule_id' => forged_rule.id,
      'touch_source' => 'automation'
    )
    expect(touch.metadata).not_to include(
      Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY,
      Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY
    )
  end

  it 'does not allow generic updates to mutate touch status' do
    touch = create(:reminder, account: account, touch_conversation: conversation, body: 'Before')

    patch "#{path}/#{touch.id}",
          params: { status: 'completed', body: 'After' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(touch.reload).to be_pending
    expect(touch.body).to eq('After')
  end

  it 'rejects updates to terminal touches' do
    touch = create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      status: :completed,
      completed_at: Time.current,
      body: 'Already sent'
    )

    patch "#{path}/#{touch.id}", params: { body: 'Mutated' }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(touch.reload).to be_completed
    expect(touch.body).to eq('Already sent')
  end

  it 'preserves internal metadata while updating a processing touch' do
    touch = create(:reminder, account: account, touch_conversation: conversation)
    active_claim = touch.mark_processing!

    patch "#{path}/#{touch.id}",
          params: { metadata: { visible: 'updated', processing_claim_token: 'forged' } },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(touch.reload).to be_processing
    expect(touch.processing_claim_token).to eq(active_claim)
    expect(touch.metadata['visible']).to eq('updated')
  end

  it 'rejects updates after a processing touch message was materialized' do
    touch = create(:reminder, account: account, touch_conversation: conversation)
    active_claim = touch.mark_processing!
    touch.mark_delivery_materialized!(123)

    patch "#{path}/#{touch.id}", params: { body: 'Too late' }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(touch.reload).to be_processing
    expect(touch.processing_claim_token).to eq(active_claim)
    expect(touch.body).not_to eq('Too late')
  end

  it 'creates and filters a communication-thread touch using display identifiers' do
    communication_thread = create(
      :communication_thread,
      account: account,
      contact: conversation.contact,
      display_id: 77
    )
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: communication_thread,
      conversation: conversation
    )

    post path,
         params: {
           remindable_type: 'CommunicationThread',
           remindable_id: communication_thread.display_id,
           conversation_id: conversation.display_id,
           target_inbox_id: conversation.inbox_id,
           scheduled_at: 1.hour.from_now.iso8601,
           timezone: 'UTC',
           body: 'Follow up in the unified thread'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    touch = account.reminders.sole
    expect(touch).to have_attributes(
      remindable: communication_thread,
      conversation: conversation
    )

    get path,
        params: {
          remindable_type: 'CommunicationThread',
          remindable_id: communication_thread.display_id,
          conversation_id: conversation.display_id
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'id')).to eq(touch.id)
    expect(response.parsed_body.dig('payload', 0, 'remindable')).to include(
      'id' => communication_thread.display_id,
      'type' => 'CommunicationThread'
    )
  end

  it 'rejects touches for records outside the current account' do
    foreign_conversation = create(:conversation)

    post path,
         params: {
           remindable_type: 'Conversation',
           remindable_id: foreign_conversation.id,
           scheduled_at: 1.hour.from_now.iso8601,
           timezone: 'UTC',
           body: 'This should not be created'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
    expect(account.reminders.count).to eq(0)
  end

  it 'approves a draft touch' do
    touch = create(
      :reminder,
      :draft,
      account: account,
      touch_conversation: conversation,
      scheduled_at: 1.hour.from_now
    )

    post "#{path}/#{touch.id}/approve", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('pending')
    expect(touch.reload).to be_pending
  end

  it 'does not reopen a completed touch through approve' do
    touch = create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      status: :completed,
      completed_at: Time.current
    )

    post "#{path}/#{touch.id}/approve", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(touch.reload).to be_completed
  end

  it 'cancels a touch' do
    touch = create(:reminder, account: account, touch_conversation: conversation)

    post "#{path}/#{touch.id}/cancel", params: { reason: 'No longer needed' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('cancelled')
    expect(touch.reload.last_error).to eq('No longer needed')
  end

  it 'deletes a pending delayed message' do
    touch = create(:reminder, account: account, touch_conversation: conversation)

    delete "#{path}/#{touch.id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(account.reminders.exists?(touch.id)).to be(false)
  end

  it 'rejects deleting a completed delayed message' do
    touch = create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      status: :completed,
      completed_at: Time.current
    )

    delete "#{path}/#{touch.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq('Only unsent delayed messages can be deleted.')
    expect(account.reminders.exists?(touch.id)).to be(true)
  end

  it 'allows custom-role users with outbound_view to list touches' do
    create(:reminder, account: account, touch_conversation: conversation)
    custom_role = create(:custom_role, account: account, permissions: ['outbound_view'])
    custom_role_user = create(:user, account: account, role: :agent)
    custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

    get path, headers: custom_role_user.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
  end
end
