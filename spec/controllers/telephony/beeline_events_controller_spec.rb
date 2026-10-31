require 'rails_helper'

RSpec.describe Telephony::BeelineEventsController, type: :controller do
  it 'does not authenticate, enqueue or ingest Beeline events while this runtime is disabled' do
    with_modified_env('TELEPHONY_BEELINE_ENABLED' => 'false') do
      expect(Channel::Voice).not_to receive(:where)
      expect(Telephony::Beeline::EventAdapter).not_to receive(:new)
      expect(Telephony::InboundRouteLifecycleJob).not_to receive(:perform_later)

      post :create, params: { token: 'test-token', event: 'CallReleased' }

      expect(response).to have_http_status(:not_found)
    end
  end
end
