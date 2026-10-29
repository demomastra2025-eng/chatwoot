require 'rails_helper'

RSpec.describe 'Contact notifications mute API', type: :request do
  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap do |record|
      record.enable_features!('scheduling', 'deferred_touch_materialization')
    end
  end
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:inbox) { shared_phone_cloud_inbox(account) }
  let(:resource) { create(:scheduling_resource, account: account) }

  before { enable_shared_phone_switches! }

  def build_direct_touch_rule
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_rescheduled',
      conditions: [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['scheduled'], 'query_operator' => nil }],
      actions: [{
        action_name: 'create_touch',
        action_params: { body: 'Visit reminder', delay_minutes: 5, target_inbox_id: inbox.id }
      }]
    )
  end

  def build_patient_appointment(holder:, patient:, conversation:)
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: holder,
      patient_contact: patient,
      conversation: conversation,
      status: 'scheduled',
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
  end

  describe 'PATCH /api/v1/accounts/:account_id/contacts/:id' do
    it 'persists notifications_muted and cancels open reminders for that shared-phone card only', :aggregate_failures do
      holder = create(:contact, account: account, name: 'Phone Owner', phone_number: SharedPhoneHelpers::FAMILY_PHONE)
      _, conversation = shared_phone_chat(account, holder, inbox, SharedPhoneHelpers::FAMILY_PHONE.delete('+'))
      placeholder = shared_phone_card(account, holder, name: 'Пмсп', code: 'pmsp-api-1')
      sibling = shared_phone_card(account, holder, name: 'Реальный пациент', code: 'sibling-api-1')
      rule = build_direct_touch_rule

      placeholder_appt = build_patient_appointment(holder: holder, patient: placeholder, conversation: conversation)
      sibling_appt = build_patient_appointment(holder: holder, patient: sibling, conversation: conversation)
      AutomationRules::AppointmentActionService.new(rule, account, placeholder_appt).perform
      AutomationRules::AppointmentActionService.new(rule, account, sibling_appt).perform
      placeholder_touch = account.reminders.find_by!(remindable: placeholder_appt)
      sibling_touch = account.reminders.find_by!(remindable: sibling_appt)

      patch "/api/v1/accounts/#{account.id}/contacts/#{placeholder.id}",
            params: { notifications_muted: true },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('payload', 'notifications_muted')).to be(true)
      expect(placeholder.reload.notifications_muted).to be(true)
      expect(placeholder_touch.reload).to be_cancelled
      expect(sibling_touch.reload).to be_pending
    end

    it 'exposes notifications_muted across contact show, shared-phone patients list, and unmute PATCH', :aggregate_failures do
      holder = create(:contact, account: account, name: 'Phone Owner', phone_number: SharedPhoneHelpers::FAMILY_PHONE)
      shared_phone_chat(account, holder, inbox, SharedPhoneHelpers::FAMILY_PHONE.delete('+'))
      placeholder = shared_phone_card(account, holder, name: 'Пмсп', code: 'pmsp-api-2')
      sibling = shared_phone_card(account, holder, name: 'Реальный пациент', code: 'sibling-api-2')
      placeholder.update!(notifications_muted: true)

      get "/api/v1/accounts/#{account.id}/contacts/#{placeholder.id}", headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('payload', 'notifications_muted')).to be(true)

      get "/api/v1/accounts/#{account.id}/scheduling/contacts/#{holder.id}/patients", headers: headers, as: :json
      expect(response).to have_http_status(:success)
      patients = response.parsed_body.dig('payload', 'patients') || response.parsed_body['patients']
      expect(patients.find { |item| item['id'] == placeholder.id }['notifications_muted']).to be(true)
      expect(patients.find { |item| item['id'] == sibling.id }['notifications_muted']).to be(false)

      patch "/api/v1/accounts/#{account.id}/contacts/#{placeholder.id}",
            params: { notifications_muted: false },
            headers: headers,
            as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('payload', 'notifications_muted')).to be(false)
      expect(placeholder.reload.notifications_muted).to be(false)
    end
  end
end
