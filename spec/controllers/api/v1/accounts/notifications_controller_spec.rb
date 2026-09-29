require 'rails_helper'

RSpec.describe 'Notifications API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/notifications' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/notifications"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let!(:notification1) { create(:notification, account: account, user: admin) }
      let!(:notification2) { create(:notification, account: account, user: admin) }

      it 'returns all notifications' do
        get "/api/v1/accounts/#{account.id}/notifications",
            headers: admin.create_new_auth_token,
            as: :json

        response_json = response.parsed_body
        expect(response).to have_http_status(:success)
        expect(response.body).to include(notification1.notification_type)
        expect(response_json['data']['meta']['unread_count']).to eq 2
        expect(response_json['data']['meta']['count']).to eq 2
        # notification appear in descending order
        expect(response_json['data']['payload'].first['id']).to eq notification2.id
        expect(response_json['data']['payload'].first['primary_actor']).not_to be_nil
      end

      describe 'communication thread targets' do
        let(:conversation) { create(:conversation, account: account) }
        let!(:thread_notification) do
          create(
            :notification,
            account: account,
            user: admin,
            notification_type: 'conversation_creation',
            primary_actor: conversation
          )
        end

        # Database lookup: the conversation object in hand may carry a stale
        # thread association when the resolver linked it on its own copy.
        def thread_for(conversation)
          existing_link = CommunicationThreadConversation.find_by(conversation_id: conversation.id)
          return existing_link.communication_thread if existing_link

          communication_thread = create(:communication_thread, account: account, contact: conversation.contact)
          create(
            :communication_thread_conversation,
            account: account,
            communication_thread: communication_thread,
            conversation: conversation
          )
          communication_thread
        end

        def notification_payload
          get "/api/v1/accounts/#{account.id}/notifications",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)
          response.parsed_body['data']['payload'].detect { |item| item['id'] == thread_notification.id }
        end

        it 'exposes the canonical communication thread target for conversation notifications' do
          account.enable_features!('communication_threads')
          communication_thread = thread_for(conversation)

          expect(notification_payload['communication_thread_id']).to eq(communication_thread.display_id)
        end

        it 'does not expose thread targets when communication threads are disabled' do
          account.disable_features!('communication_threads')
          thread_for(conversation)

          expect(notification_payload['communication_thread_id']).to be_nil
        end

        it 'returns no thread target for a conversation outside any thread' do
          account.enable_features!('communication_threads')
          CommunicationThreadConversation.where(conversation_id: conversation.id).delete_all

          expect(notification_payload['communication_thread_id']).to be_nil
        end

        it 'returns the same thread target as the realtime notification payload' do
          account.enable_features!('communication_threads')
          communication_thread = thread_for(conversation)

          thread_id = notification_payload['communication_thread_id']

          expect(thread_id).to eq(communication_thread.display_id)
          expect(Notification.find(thread_notification.id).push_event_data[:communication_thread_id]).to eq(thread_id)
        end

        it 'ignores a stale thread link whose thread belongs to another contact' do
          account.enable_features!('communication_threads')
          thread_for(conversation)
          # Skip callbacks so the thread resolver cannot relink the conversation.
          conversation.update_columns(contact_id: create(:contact, account: account).id) # rubocop:disable Rails/SkipsModelValidations

          expect(notification_payload['communication_thread_id']).to be_nil
          expect(Notification.find(thread_notification.id).push_event_data[:communication_thread_id]).to be_nil
        end
      end

      it 'returns orphaned notifications using the stored snapshot' do
        conversation = create(:conversation, :with_assignee, account: account)
        notification = create(
          :notification,
          account: account,
          user: admin,
          notification_type: 'conversation_creation',
          primary_actor: conversation
        )
        conversation.destroy!

        get "/api/v1/accounts/#{account.id}/notifications",
            headers: admin.create_new_auth_token,
            as: :json

        response_json = response.parsed_body
        payload = response_json['data']['payload'].detect { |item| item['id'] == notification.id }

        expect(response).to have_http_status(:success)
        expect(payload['primary_actor']['id']).to eq(conversation.display_id)
        expect(payload['primary_actor']['inbox_id']).to eq(conversation.inbox_id)
        expect(payload['push_message_title']).to include("##{conversation.display_id}")
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/notifications/read_all' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let!(:notification1) { create(:notification, account: account, user: admin) }
    let!(:notification2) { create(:notification, account: account, user: admin) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/notifications/read_all"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'updates all the notifications read at' do
        post "/api/v1/accounts/#{account.id}/notifications/read_all",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(notification1.reload.read_at).not_to eq('')
        expect(notification2.reload.read_at).not_to eq('')
      end

      it 'updates only the notifications read at for primary actor when param is passed' do
        post "/api/v1/accounts/#{account.id}/notifications/read_all",
             headers: admin.create_new_auth_token,
             params: {
               primary_actor_id: notification1.primary_actor_id,
               primary_actor_type: notification1.primary_actor_type
             },
             as: :json

        expect(response).to have_http_status(:success)
        expect(notification1.reload.read_at).not_to eq('')
        expect(notification2.reload.read_at).to be_nil
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/notifications/:id' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let!(:notification) { create(:notification, account: account, user: admin) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/notifications/#{notification.id}",
            params: { read_at: true }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'updates the notification read at' do
        patch "/api/v1/accounts/#{account.id}/notifications/#{notification.id}",
              headers: admin.create_new_auth_token,
              params: { read_at: true },
              as: :json

        expect(response).to have_http_status(:success)
        expect(notification.reload.read_at).not_to eq('')
      end

      it 'returns not found for another account notification' do
        other_account = create(:account)
        other_notification = create(:notification, account: other_account, user: admin)

        patch "/api/v1/accounts/#{account.id}/notifications/#{other_notification.id}",
              headers: admin.create_new_auth_token,
              params: { read_at: true },
              as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/notifications/unread_count' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/notifications/unread_count"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'returns notifications unread count' do
        2.times.each { create(:notification, account: account, user: admin) }
        get "/api/v1/accounts/#{account.id}/notifications/unread_count",
            headers: admin.create_new_auth_token,
            as: :json

        response_json = response.parsed_body
        expect(response).to have_http_status(:success)
        expect(response_json).to eq 2
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/notifications/:id' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let!(:notification) { create(:notification, account: account, user: admin) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/notifications/#{notification.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'deletes the notification' do
        delete "/api/v1/accounts/#{account.id}/notifications/#{notification.id}",
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(Notification.count).to eq(0)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/notifications/:id/snooze' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let!(:notification) { create(:notification, account: account, user: admin) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/notifications/#{notification.id}/snooze",
             params: { snoozed_until: DateTime.now.utc + 1.day }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'updates the notification snoozed until' do
        post "/api/v1/accounts/#{account.id}/notifications/#{notification.id}/snooze",
             headers: admin.create_new_auth_token,
             params: { snoozed_until: DateTime.now.utc + 1.day },
             as: :json

        expect(response).to have_http_status(:success)
        expect(notification.reload.snoozed_until).not_to eq('')
        expect(notification.reload.meta['last_snoozed_at']).to be_nil
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/notifications/:id/unread' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let!(:notification) { create(:notification, account: account, user: admin) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/notifications/#{notification.id}/unread"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'updates the notification read at' do
        post "/api/v1/accounts/#{account.id}/notifications/#{notification.id}/unread",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(notification.reload.read_at).to be_nil
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/notifications/destroy_all' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let(:notification1) { create(:notification, account: account, user: admin) }
    let(:notification2) { create(:notification, account: account, user: admin) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/notifications/destroy_all"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'deletes all the read notifications' do
        expect(Notification::DeleteNotificationJob).to receive(:perform_later).with(admin, account, type: :read)

        post "/api/v1/accounts/#{account.id}/notifications/destroy_all",
             headers: admin.create_new_auth_token,
             params: { type: 'read' },
             as: :json

        expect(response).to have_http_status(:success)
      end

      it 'deletes all the notifications' do
        expect(Notification::DeleteNotificationJob).to receive(:perform_later).with(admin, account, type: :all)

        post "/api/v1/accounts/#{account.id}/notifications/destroy_all",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
      end
    end
  end
end
