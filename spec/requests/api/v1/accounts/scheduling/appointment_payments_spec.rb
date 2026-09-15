require 'rails_helper'

RSpec.describe 'Scheduling Appointment Payments API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:resource) { create(:scheduling_resource, account: account, user: agent) }
  let(:access_role) { account.account_users.find_by!(user: agent).access_role }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      service_amount: 20_000,
      payment_status: 'awaiting_payment'
    )
  end
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}/payments" }

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
    AccessControl::SystemRoleBootstrapper.call(account: account)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    set_appointment_grant('manage_finance', 'all')
    set_appointment_grant('view_finance', 'none')
    account.authorize_access_control_mode_transition do
      account.update!(access_control_mode: 'enforced')
    end
  end

  def set_appointment_grant(capability, access_scope)
    grant = access_role.grants.find_or_initialize_by(resource: 'appointments', capability: capability)
    grant.update!(account: account, access_scope: access_scope)
  end

  %w[own all].each do |manage_scope|
    context "with manage_finance=#{manage_scope} and view_finance=none" do
      before do
        set_appointment_grant('manage_finance', manage_scope)
      end

      it 'masks finance fields after adding a payment' do
        post path, params: { amount: 5_000, payment_method: 'cash' }, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch('payload').keys).not_to include(
          *Scheduling::PayloadBuilder::APPOINTMENT_FINANCE_KEYS.map(&:to_s)
        )
      end

      it 'masks finance fields after cancelling payments' do
        create(
          :scheduling_payment,
          account: account,
          appointment: appointment,
          amount: 5_000,
          payment_method: 'cash',
          payment_kind: 'payment'
        )

        delete path, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch('payload').keys).not_to include(
          *Scheduling::PayloadBuilder::APPOINTMENT_FINANCE_KEYS.map(&:to_s)
        )
      end
    end
  end
end
