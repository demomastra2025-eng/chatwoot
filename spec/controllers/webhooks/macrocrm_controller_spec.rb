require 'rails_helper'

RSpec.describe 'Webhooks::MacrocrmController', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:hook) do
    create(:integrations_hook,
           account: account,
           app_id: 'macrocrm',
           access_token: 'macro-secret',
           reference_id: 'macro-key-123',
           settings: {
             'app_id' => 'macro-app',
             'sync_incoming_messages' => true,
             'sync_outgoing_messages' => true
           })
  end
  let(:payload) do
    {
      action: 'estate.managerChanged',
      data: {
        event: 'estate.managerChanged',
        object: {
          estate_id: 6841608,
          client_phones: '+7 700 123 45 67',
          status: 10,
          updated_at: '2026-03-28 18:53:43'
        }
      }
    }
  end

  describe 'POST /webhooks/macrocrm/:webhook_key/manager_changed' do
    it 'enqueues async processing for a known webhook key' do
      expect do
        post "/webhooks/macrocrm/#{hook.reference_id}/manager_changed",
             params: payload,
             as: :json
      end.to have_enqueued_job(Integrations::Macrocrm::ManagerChangedJob).with(
        hook.id,
        hash_including(
          'action' => 'estate.managerChanged',
          'data' => hash_including(
            'event' => 'estate.managerChanged',
            'object' => hash_including('estate_id' => 6841608)
          )
        )
      )

      expect(response).to have_http_status(:success)
    end

    it 'returns 200 even when the webhook key is unknown' do
      post '/webhooks/macrocrm/unknown-key/manager_changed',
           params: payload,
           as: :json

      expect(response).to have_http_status(:success)
    end

    it 'falls back to inline processing if enqueueing fails' do
      processor = instance_double(
        Integrations::Macrocrm::ManagerChangedProcessorService,
        perform: true
      )

      allow(Integrations::Macrocrm::ManagerChangedJob).to receive(:perform_later)
        .and_raise(ActiveJob::EnqueueError)
      allow(Integrations::Macrocrm::ManagerChangedProcessorService).to receive(:new)
        .and_return(processor)

      post "/webhooks/macrocrm/#{hook.reference_id}/manager_changed",
           params: payload,
           as: :json

      expect(Integrations::Macrocrm::ManagerChangedProcessorService)
        .to have_received(:new)
        .with(hook: hook, payload: hash_including('action' => 'estate.managerChanged'))
      expect(processor).to have_received(:perform)
      expect(response).to have_http_status(:success)
    end
  end
end
