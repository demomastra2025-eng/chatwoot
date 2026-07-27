require 'rails_helper'

RSpec.describe 'Touch Plan Enrollments API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:enrollment) { create(:touch_plan_enrollment, account: account) }
  let(:index_path) { "/api/v1/accounts/#{account.id}/touch_plan_enrollments" }
  let(:cancel_path) { "#{index_path}/#{enrollment.id}/cancel" }

  it 'lists open enrollments for the filtered entity' do
    active_enrollment = enrollment
    create(:touch_plan_enrollment, :cancelled, account: account, remindable: active_enrollment.remindable)

    get index_path,
        params: {
          remindable_type: active_enrollment.remindable_type,
          remindable_id: active_enrollment.remindable_id
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to contain_exactly(
      hash_including(
        'id' => active_enrollment.id,
        'status' => 'active',
        'reminder_group_name' => active_enrollment.reminder_group.name
      )
    )
  end

  it 'cancels an active enrollment and its unmaterialized reminder' do
    reminder = create(
      :reminder,
      account: account,
      remindable: enrollment.remindable,
      reminder_group: enrollment.reminder_group,
      metadata: { 'touch_plan_enrollment_id' => enrollment.id }
    )
    create(
      :touch_occurrence_claim,
      account: account,
      touch_plan_enrollment: enrollment,
      reminder: reminder,
      status: 'materialized'
    )

    post cancel_path, params: { reason: 'no longer needed' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('cancelled')
    expect(enrollment.reload).to be_cancelled
    expect(reminder.reload).to be_cancelled
  end

  it 'does not expose enrollments from another account' do
    other_enrollment = create(:touch_plan_enrollment, account: create(:account))

    post "/api/v1/accounts/#{account.id}/touch_plan_enrollments/#{other_enrollment.id}/cancel",
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_enrollment.reload).to be_active
  end
end
