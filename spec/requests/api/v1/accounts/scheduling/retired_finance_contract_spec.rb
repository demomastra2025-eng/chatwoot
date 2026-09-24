require 'rails_helper'

RSpec.describe 'Retired scheduling finance contract', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, status: 'cancelled', service_amount: 2000)
  end
  let(:headers) { admin.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}" }
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

  it 'rejects retired write fields instead of silently accepting manual price overrides' do
    expect do
      post "/api/v1/accounts/#{account.id}/scheduling/appointments",
           params: { resource_id: resource.id, service_amount: 9999 }, headers: headers, as: :json
    end.not_to change(Scheduling::Appointment, :count)
    expect(response).to have_http_status(:unprocessable_content)

    put path, params: { prepaid_amount: 9999 }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(appointment.reload.service_amount).to eq(2000)
  end
end
