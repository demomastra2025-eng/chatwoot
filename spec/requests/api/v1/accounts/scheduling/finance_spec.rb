require 'rails_helper'

RSpec.describe 'Scheduling Finance API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:contact) { create(:contact, account: account, name: 'Patient') }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      service: service,
      service_amount: 20_000,
      payment_status: 'paid',
      settlement_amount: 20_000,
      settlement_payment_method: 'cash'
    )
  end

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
  end

  def response_body
    response.parsed_body
  end

  it 'blocks finance journal endpoints when scheduling_finance is disabled' do
    account.disable_features!('scheduling_finance')

    get "/api/v1/accounts/#{account.id}/scheduling/payments", headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response_body['code']).to eq('FEATURE_DISABLED')
  end

  it 'blocks finance mutations when scheduling_finance is disabled' do
    account.disable_features!('scheduling_finance')

    post "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/payments",
         params: { amount: 1000, payment_method: 'cash' },
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response_body['code']).to eq('FEATURE_DISABLED')
  end

  it 'prevents payment cancellation after expense payout is marked paid' do
    create(:scheduling_payment, appointment: appointment, account: account, amount: 20_000, payment_method: 'cash', payment_kind: 'payment')
    expense = create(:scheduling_expense, appointment: appointment, account: account, resource: resource, amount: 8_000, status: 'unpaid')

    post "/api/v1/accounts/#{account.id}/scheduling/expenses/#{expense.id}/pay",
         headers: admin.create_new_auth_token,
         as: :json

    delete "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/payments",
           headers: agent.create_new_auth_token,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('VALIDATION_ERROR')
  end

  it 'includes fixed plus percent compensation in generated expenses' do
    appointment.update!(
      payment_status: 'awaiting_payment',
      settlement_amount: 0,
      settlement_payment_method: nil,
      compensation_type_snapshot: 'fixed_plus_percent',
      compensation_value_snapshot: 4_000,
      compensation_percent_snapshot: 10
    )

    post "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/payments",
         params: { amount: 20_000, payment_method: 'cash' },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(appointment.reload.expense.amount).to eq(6_000)
  end

  it 'blocks marking an appointment as paid when required custom fields are missing' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      required: true
    )
    unpaid_appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      service: service,
      service_amount: 20_000,
      payment_status: 'awaiting_payment',
      prepaid_amount: 0,
      settlement_amount: 0,
      settlement_payment_method: nil,
      custom_attributes: {}
    )

    post "/api/v1/accounts/#{account.id}/scheduling/appointments/#{unpaid_appointment.id}/payments",
         params: { amount: 20_000, payment_method: 'cash' },
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('APPOINTMENT_PAYMENT_REQUIRES_FIELDS')
    expect(response_body['error']).to include('Visit reason')
    expect(response_body.dig('details', 'missing_fields')).to include(
      { 'key' => 'visit_reason', 'label' => 'Visit reason' }
    )
    expect(unpaid_appointment.reload.payment_status).to eq('awaiting_payment')
    expect(unpaid_appointment.payments).to be_empty
  end
end
