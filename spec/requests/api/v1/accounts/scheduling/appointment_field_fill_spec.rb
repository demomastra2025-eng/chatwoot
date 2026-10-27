require 'rails_helper'

RSpec.describe 'Appointment field fill API', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:agent) { create(:user, account: account, role: :agent) }

  it 'returns upcoming field fill statistics to a scheduling agent' do
    create(:scheduling_appointment, account: account, starts_at: 2.days.from_now,
                                    ends_at: 2.days.from_now + 30.minutes, service_name_snapshot: nil)

    get "/api/v1/accounts/#{account.id}/scheduling/appointment_field_fill",
        params: { field_ids: ['appointment.service_name_snapshot'] }, headers: agent.create_new_auth_token

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to contain_exactly(
      include('field_id' => 'appointment.service_name_snapshot', 'total' => 1, 'empty' => 1, 'blocking' => true)
    )
  end
end
