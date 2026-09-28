require 'rails_helper'

RSpec.describe 'Retired scheduling finance contract', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, status: 'cancelled', service_amount: 2000)
  end
  let(:editable_appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact,
                                    starts_at: booking_day, ends_at: booking_day + 30.minutes,
                                    status: 'scheduled', service_amount: 2000)
  end
  let(:headers) { admin.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}" }
  let(:booking_day) do
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    day = zone.today.next_occurring(:monday)
    zone.local(day.year, day.month, day.day, 10)
  end
  let(:booking_params) do
    { resource_id: resource.id, contact_id: contact.id, service_id: service.id,
      starts_at: booking_day.iso8601, ends_at: (booking_day + 30.minutes).iso8601,
      client_name: 'Test Patient' }
  end
  let(:contact) { create(:contact, account: account, name: 'Test Patient') }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:work_rule) do
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1,
                                  start_minute: 9 * 60, end_minute: 18 * 60)
  end
  let(:payment) do
    create(:scheduling_payment, account: account, appointment: appointment, amount: 1000,
                                payment_method: 'cash', payment_kind: 'payment')
  end
  let(:expense) do
    create(:scheduling_expense, account: account, appointment: appointment, resource: resource,
                                amount: 300, status: 'unpaid')
  end

  it 'does not route the retired payment and expense journals or mutations' do
    %w[payments expenses appointments/123/payments expenses/123/pay expenses/pay_all].each do |route|
      get "/api/v1/accounts/#{account.id}/scheduling/#{route}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    %w[payments expenses].each do |route|
      post "/api/v1/accounts/#{account.id}/scheduling/#{route}", headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
    %w[appointments/123/payments expenses/pay_all expenses/123/pay].each do |route|
      post "/api/v1/accounts/#{account.id}/scheduling/#{route}", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch('code')).to eq('RETIRED_FINANCE_MUTATION')
    end
    delete "/api/v1/accounts/#{account.id}/scheduling/appointments/123/payments", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('code')).to eq('RETIRED_FINANCE_MUTATION')
    delete "/api/v1/accounts/#{account.id}/scheduling/appointments/123/payments/456", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'keeps historical rows without exposing them in appointment responses' do
    payment
    expense

    get path, headers: headers
    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload.fetch('service_amount')).to eq(2000)
    expect(payload.keys).not_to include('payment_status', 'prepaid_amount', 'payments', 'expense',
                                        'compensation_type_snapshot', 'settlement_amount')
  end

  it 'refuses to delete an appointment with historical finance rows via API or model' do
    payment
    expense

    delete path, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('code')).to eq('HISTORICAL_DATA_RETAINED')
    expect(appointment.reload).to be_present
    expect(payment.reload).to be_present
    expect(expense.reload).to be_present
    expect { appointment.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  # Pinned old browser payload branches: appointmentForm.js blob 6f97e969 (manual price/advance),
  # SchedulingConversationAppointmentsSidebar.vue blob bd70ff7d (manual price).
  it 'refuses old calendar manual-price and advance creates without writes, with actionable text' do
    old_payloads = [
      booking_params.except(:service_id).merge(service_amount: 9999),
      booking_params.merge(prepaid_amount: 1000, prepaid_payment_method: 'cash'),
      booking_params.merge(prepaid_amount: 0)
    ]
    old_payloads.each do |old_payload|
      expect do
        post "/api/v1/accounts/#{account.id}/scheduling/appointments",
             params: old_payload, headers: headers, as: :json
      end.not_to change(Scheduling::Appointment, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'RETIRED_FINANCE_FIELDS')
      expect(response.parsed_body.fetch('error')).to include('Скопируйте', 'ручного обновления', 'без аванса')
    end
  end

  it 'refuses an old calendar advance or sidebar manual-price edit without changing the appointment' do
    original = editable_appointment.attributes.slice('service_amount', 'prepaid_amount', 'client_comment', 'updated_at')
    [{ prepaid_amount: 9999, prepaid_payment_method: 'cash' }, { service_amount: 9999 }].each do |money|
      patch "/api/v1/accounts/#{account.id}/scheduling/appointments/#{editable_appointment.id}",
            params: money.merge(client_comment: 'Не сохранять'), headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'RETIRED_FINANCE_FIELDS')
      expect(editable_appointment.reload.attributes.slice(*original.keys)).to eq(original)
    end
  end

  it 'refuses the old payload before an idempotent create can return success' do
    existing = create(:scheduling_appointment, account: account, resource: resource, idempotency_key: 'existing-booking')
    post "/api/v1/accounts/#{account.id}/scheduling/appointments",
         params: booking_params.merge(idempotency_key: existing.idempotency_key, prepaid_amount: 0, owner_id: admin.id),
         headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('code')).to eq('RETIRED_FINANCE_FIELDS')
    expect(existing.reload.idempotency_key).to eq('existing-booking')
  end

  it 'rejects finance before legacy owner on update, preserving the appointment and contact owner' do
    editable_appointment
    snapshot = editable_appointment.attributes.slice('service_amount', 'client_comment', 'updated_at')
    patch "/api/v1/accounts/#{account.id}/scheduling/appointments/#{editable_appointment.id}",
          params: { service_amount: 0, owner_id: admin.id, client_comment: 'Не сохранять' }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('code')).to eq('RETIRED_FINANCE_FIELDS')
    expect(editable_appointment.reload.attributes.slice(*snapshot.keys)).to eq(snapshot)
    expect(contact.reload.owner_id).to be_nil
  end

  it 'rejects raw and nested finance before an idempotent create or persistence' do
    key = 'same-old-form'
    create(:scheduling_appointment, account: account, resource: resource, idempotency_key: key)
    [{ service_amount: 0 }, { appointment: { payment_status: 'paid' } },
     { 'appointment' => { 'prepaid_amount' => 0 } }].each do |money|
      expect(Integrations::Medelement::AppointmentProviderCommandReceiptLookupService).not_to receive(:new)
      expect do
        post "/api/v1/accounts/#{account.id}/scheduling/appointments",
             params: booking_params.merge(idempotency_key: key).merge(money), headers: headers, as: :json
      end.not_to change(Scheduling::Appointment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch('code')).to eq('RETIRED_FINANCE_FIELDS')
    end
  end

  it 'rejects nested finance on an ordinary update without persisting any fields' do
    original = editable_appointment.attributes.slice('client_comment', 'service_amount', 'updated_at')
    patch "/api/v1/accounts/#{account.id}/scheduling/appointments/#{editable_appointment.id}",
          params: { client_comment: 'Discarded', appointment: { settlement_amount: 0 } },
          headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('code')).to eq('RETIRED_FINANCE_FIELDS')
    expect(editable_appointment.reload.attributes.slice(*original.keys)).to eq(original)
  end

  it 'accepts a non-finance old calendar payload and derives catalog pricing' do
    work_rule
    post "/api/v1/accounts/#{account.id}/scheduling/appointments",
         params: booking_params, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    saved = Scheduling::Appointment.find(response.parsed_body.dig('payload', 'id'))
    expect(saved).to have_attributes(service: service, service_amount: 20_000)
  end

  it 'allows an ordinary old-client edit without reviving historical finance writes' do
    work_rule
    patch "/api/v1/accounts/#{account.id}/scheduling/appointments/#{editable_appointment.id}",
          params: { client_comment: 'Обычная правка' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(editable_appointment.reload).to have_attributes(client_comment: 'Обычная правка', service_amount: 2000)
  end

  it 'does not trust an old browser administrator token when the new API has removed its create grant' do
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
    account.account_users.find_by!(user: admin).access_role.grants
           .find_by!(resource: 'appointments', capability: 'create').update!(access_scope: 'none')

    expect do
      post "/api/v1/accounts/#{account.id}/scheduling/appointments",
           params: booking_params, headers: headers, as: :json
    end.not_to change(Scheduling::Appointment, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects retired fields at the service boundary for non-HTTP callers as well' do
    [{ service_amount: 0, owner_id: admin.id }, { 'prepaid_amount' => 0, 'owner_id' => admin.id }].each do |finance_params|
      expect do
        Scheduling::Appointments::UpsertService.new(
          account: account, params: booking_params.merge(finance_params), actor: admin
        ).perform
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('RETIRED_FINANCE_FIELDS') }
    end
    expect(Scheduling::Appointment.where(account: account)).not_to exist
  end
end
