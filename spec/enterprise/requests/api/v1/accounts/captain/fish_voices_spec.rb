require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::FishVoices', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { admin.create_new_auth_token }
  let(:client) { instance_spy(Telephony::AiVoice::FishAudioClient) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/captain/fish_voices" }

  before do
    allow(Telephony::AiVoice::FishAudioClient).to receive(:new).and_return(client)
  end

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def create_voice(overrides = {})
    Telephony::AiVoice::FishVoice.create!(
      {
        account: account,
        created_by: admin,
        provider_model_id: SecureRandom.hex(16),
        title: 'Support voice',
        state: 'trained',
        visibility: 'private'
      }.merge(overrides)
    )
  end

  describe 'GET /api/v1/accounts/:account_id/captain/fish_voices' do
    it 'requires authentication' do
      get base_path, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'requires administrator access' do
      get base_path, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns only the current account registry' do
      voice = create_voice
      create_voice(account: other_account, created_by: nil, title: 'Other account voice')

      get base_path, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response[:payload]).to contain_exactly(
        hash_including(id: voice.id, reference_id: voice.provider_model_id, title: 'Support voice', state: 'trained')
      )
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/fish_voices' do
    let(:audio) { fixture_file_upload('public/audio/widget/ding.mp3', 'audio/mpeg') }
    let(:provider_model) do
      {
        '_id' => 'fish-model-123',
        'title' => 'Kazakh support',
        'state' => 'created',
        'visibility' => 'private'
      }
    end

    it 'requires explicit voice rights confirmation' do
      post base_path,
           params: { title: 'Kazakh support', voice: audio, consent_confirmed: false },
           headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response).to eq(error: 'fish_voice_consent_required')
      expect(client).not_to have_received(:create_model)
    end

    it 'creates a private account-scoped Fish voice registry entry' do
      allow(client).to receive(:create_model).and_return(provider_model)

      expect do
        post base_path,
             params: {
               title: 'Kazakh support',
               transcript: 'Сәлеметсіз бе',
               voice: audio,
               consent_confirmed: true
             },
             headers: headers
      end.to change(Telephony::AiVoice::FishVoice, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(json_response[:payload]).to include(
        reference_id: 'fish-model-123',
        title: 'Kazakh support',
        state: 'created',
        visibility: 'private'
      )
      expect(client).to have_received(:create_model).with(
        title: 'Kazakh support',
        upload: kind_of(ActionDispatch::Http::UploadedFile),
        transcript: 'Сәлеметсіз бе'
      )
      expect(Telephony::AiVoice::FishVoice.last).to have_attributes(account: account, created_by: admin)
    end

    it 'does not delete an existing provider voice when Fish returns a registered id' do
      create_voice(provider_model_id: provider_model['_id'])
      allow(client).to receive(:create_model).and_return(provider_model)

      post base_path,
           params: { title: 'Duplicate', voice: audio, consent_confirmed: true },
           headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response).to eq(error: 'fish_voice_registry_failed')
      expect(client).not_to have_received(:delete_model)
    end

    it 'does not delete the provider model when registry safety cannot be checked' do
      allow(client).to receive(:create_model).and_return(provider_model)
      allow(Telephony::AiVoice::FishVoice).to receive(:transaction)
        .and_raise(ActiveRecord::StatementInvalid, 'registry unavailable')

      post base_path,
           params: { title: 'Registry unavailable', voice: audio, consent_confirmed: true },
           headers: headers

      expect(response).to have_http_status(:service_unavailable)
      expect(json_response).to eq(error: 'fish_voice_registry_failed')
      expect(client).not_to have_received(:delete_model)
    end

    it 'deletes a provider model that was not created as private' do
      allow(client).to receive(:create_model).and_return(provider_model.merge('visibility' => 'public'))
      allow(client).to receive(:delete_model).with(provider_model['_id']).and_return(true)

      expect do
        post base_path,
             params: { title: 'Unsafe visibility', voice: audio, consent_confirmed: true },
             headers: headers
      end.not_to change(Telephony::AiVoice::FishVoice, :count)

      expect(response).to have_http_status(:bad_gateway)
      expect(json_response).to eq(error: 'fish_voice_invalid_response')
      expect(client).to have_received(:delete_model).with(provider_model['_id'])
    end

    it 'rejects a malformed successful provider response' do
      allow(client).to receive(:create_model).and_return(['unexpected'])

      expect do
        post base_path,
             params: { title: 'Malformed response', voice: audio, consent_confirmed: true },
             headers: headers
      end.not_to change(Telephony::AiVoice::FishVoice, :count)

      expect(response).to have_http_status(:bad_gateway)
      expect(json_response).to eq(error: 'fish_voice_invalid_response')
      expect(client).not_to have_received(:delete_model)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/captain/fish_voices/:id' do
    it 'refreshes training state from Fish Audio' do
      voice = create_voice(state: 'created')
      allow(client).to receive(:model).with(voice.provider_model_id).and_return(
        '_id' => voice.provider_model_id,
        'title' => 'Support voice trained',
        'state' => 'trained',
        'visibility' => 'private'
      )

      get "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response[:payload]).to include(state: 'trained', title: 'Support voice trained')
      expect(voice.reload).to have_attributes(state: 'trained', title: 'Support voice trained')
    end

    it 'marks a provider-missing voice as failed so polling terminates' do
      voice = create_voice(state: 'training')
      allow(client).to receive(:model).with(voice.provider_model_id).and_raise(
        Telephony::AiVoice::FishAudioClient::NotFoundError.new('missing', http_status: 404)
      )

      get "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response[:payload]).to include(state: 'failed', provider_missing: true)
      expect(voice.reload.state).to eq('failed')
    end

    it 'rejects provider details for a different model id' do
      voice = create_voice(state: 'training')
      allow(client).to receive(:model).with(voice.provider_model_id).and_return(
        '_id' => 'different-model',
        'title' => 'Wrong model',
        'state' => 'trained',
        'visibility' => 'private'
      )

      get "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(json_response).to eq(error: 'fish_voice_invalid_response')
      expect(voice.reload).to have_attributes(state: 'training', title: 'Support voice')
    end

    it 'does not refresh a voice while deletion reconciliation is pending' do
      voice = create_voice(state: 'deleting')

      get "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response[:payload]).to include(state: 'deleting')
      expect(client).not_to have_received(:model)
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/captain/assistants/:id' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:assistant_path) { "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}" }

    it 'accepts an account-owned Fish voice reference' do
      voice = create_voice

      patch assistant_path,
            params: { assistant: { config: { voice_settings: { provider: 'fish', voice: voice.provider_model_id } } } },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(assistant.reload.config.dig('voice_settings', 'voice')).to eq(voice.provider_model_id)
    end

    it 'rejects a Fish voice reference owned by another account' do
      voice = create_voice(account: other_account, created_by: nil)

      patch assistant_path,
            params: { assistant: { config: { voice_settings: { provider: 'fish', voice: voice.provider_model_id } } } },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response).to eq(error: 'fish_voice_invalid_reference')
      expect(assistant.reload.config.dig('voice_settings', 'voice')).not_to eq(voice.provider_model_id)
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/captain/fish_voices/:id' do
    it 'blocks deletion while an assistant uses the voice' do
      voice = create_voice
      create(
        :captain_assistant,
        account: account,
        config: { 'voice_settings' => { 'provider' => 'fish', 'voice' => voice.provider_model_id } }
      )

      delete "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response).to eq(error: 'fish_voice_in_use')
      expect(client).not_to have_received(:delete_model)
      expect(voice.reload).to be_persisted
    end

    it 'deletes the provider model before removing the local registry entry' do
      voice = create_voice
      allow(client).to receive(:delete_model).with(voice.provider_model_id).and_return(true)

      expect do
        delete "#{base_path}/#{voice.id}", headers: headers, as: :json
      end.to change(Telephony::AiVoice::FishVoice, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      expect(client).to have_received(:delete_model).with(voice.provider_model_id)
    end

    it 'removes a stale local entry when Fish Audio already deleted the model' do
      voice = create_voice
      allow(client).to receive(:delete_model).and_raise(
        Telephony::AiVoice::FishAudioClient::NotFoundError.new('missing', http_status: 404)
      )

      delete "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:no_content)
      expect(Telephony::AiVoice::FishVoice).not_to exist(voice.id)
    end

    it 'restores the selectable state when provider deletion fails' do
      voice = create_voice
      allow(client).to receive(:delete_model).and_raise(
        Telephony::AiVoice::FishAudioClient::Error.new('provider unavailable', http_status: 503)
      )

      delete "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(json_response).to eq(error: 'fish_voice_delete_failed')
      expect(voice.reload.state).to eq('trained')
    end

    it 'keeps a non-selectable reconciliation marker when local deletion fails' do
      voice = create_voice
      allow(client).to receive(:delete_model).with(voice.provider_model_id).and_return(true)
      # rubocop:disable RSpec/AnyInstance -- controller reloads the locked record before destroy
      allow_any_instance_of(Telephony::AiVoice::FishVoice).to receive(:destroy!).and_raise(
        ActiveRecord::StatementInvalid,
        'registry unavailable'
      )
      # rubocop:enable RSpec/AnyInstance

      delete "#{base_path}/#{voice.id}", headers: headers, as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(json_response).to eq(error: 'fish_voice_registry_failed')
      expect(voice.reload.state).to eq('deleting')
    end

    it 'serializes deletion with selecting the same voice on an assistant' do
      voice = create_voice
      assistant = create(:captain_assistant, account: account)
      provider_delete_started = Queue.new
      release_provider_delete = Queue.new
      allow(client).to receive(:delete_model).with(voice.provider_model_id) do
        provider_delete_started << true
        release_provider_delete.pop
        true
      end

      delete_session = ActionDispatch::Integration::Session.new(Rails.application)
      update_session = ActionDispatch::Integration::Session.new(Rails.application)
      delete_thread = Thread.new do
        delete_session.delete("#{base_path}/#{voice.id}", headers: headers, as: :json)
      end
      provider_delete_started.pop
      update_thread = Thread.new do
        update_session.patch(
          "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
          params: { assistant: { config: { voice_settings: { provider: 'fish', voice: voice.provider_model_id } } } },
          headers: headers,
          as: :json
        )
      end

      expect(update_thread.join(1)).to eq(update_thread)
      expect(update_session.response).to have_http_status(:unprocessable_content)
      release_provider_delete << true
      delete_thread.value
      update_thread.value

      expect(delete_session.response).to have_http_status(:no_content)
      expect(assistant.reload.config.dig('voice_settings', 'voice')).not_to eq(voice.provider_model_id)
    ensure
      release_provider_delete << true if delete_thread&.alive?
      delete_thread&.join
      update_thread&.join
    end
  end
end
