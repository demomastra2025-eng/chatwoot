require 'rails_helper'

RSpec.describe 'removed touch plan routes', type: :routing do
  it 'does not route plan CRUD or application requests' do
    path = '/api/v1/accounts/1/touch_plans'
    expect(get: path).not_to be_routable
    expect(post: path).not_to be_routable
    expect(patch: "#{path}/2").not_to be_routable
    expect(post: "#{path}/2/apply").not_to be_routable
    expect(post: "#{path}/2/archive").not_to be_routable
    expect(get: '/api/v1/accounts/1/touch_plan_enrollments').not_to be_routable
    expect(post: '/api/v1/accounts/1/touch_plan_enrollments/2/cancel').not_to be_routable
  end
end
