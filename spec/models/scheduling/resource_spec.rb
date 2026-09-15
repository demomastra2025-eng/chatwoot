require 'rails_helper'

RSpec.describe Scheduling::Resource do
  describe 'scheduling scope invalidation' do
    it 'invalidates the account scope when the owning team changes' do
      resource = create(:scheduling_resource)
      next_team = create(:team, account: resource.account)
      allow(Scheduling::ScopeInvalidation).to receive(:dispatch)

      resource.update!(team: next_team)

      expect(Scheduling::ScopeInvalidation).to have_received(:dispatch).with(resource.account)
    end
  end
end
