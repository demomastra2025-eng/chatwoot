require 'rails_helper'

describe Notification::PushNotificationService do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:notification) { create(:notification, user: user, account: user.accounts.first) }
  let(:fcm_double) { instance_double(FCM) }
  let(:fcm_service_double) { instance_double(Notification::FcmService, fcm_client: fcm_double) }

  describe '#perform' do
    context 'when the vendor relay is retired' do
      before do
        allow(ChatwootHub).to receive(:send_push)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
        allow(WebPush).to receive(:payload_send).and_return(true)
      end

      it 'preserves browser push without sending a mobile push to the vendor' do
        with_modified_env('ONELINK_UPSTREAM_HUB_ENABLED' => 'false', 'ENABLE_PUSH_RELAY_SERVER' => 'true', 'VAPID_PUBLIC_KEY' => 'test') do
          create(:notification_subscription, user: notification.user)
          create(:notification_subscription, user: notification.user, subscription_type: 'fcm', identifier: 'mobile-test')

          described_class.new(notification: notification).perform

          expect(WebPush).to have_received(:payload_send).once
          expect(ChatwootHub).not_to have_received(:send_push)
        end
      end
    end

    context 'when the push server returns success' do
      before do
        allow(WebPush).to receive(:payload_send).and_return(true)
        allow(Rails.logger).to receive(:info)
        allow(Notification::FcmService).to receive(:new).and_return(fcm_service_double)
        allow(fcm_double).to receive(:send_v1).and_return({ body: { 'results': [] }.to_json })
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return('test_project_id')
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS', nil).and_return('test_credentials')
      end

      it 'sends webpush notifications for webpush subscription' do
        with_modified_env VAPID_PUBLIC_KEY: 'test' do
          create(:notification_subscription, user: notification.user)

          described_class.new(notification: notification).perform
          expect(WebPush).to have_received(:payload_send)
          expect(Notification::FcmService).not_to have_received(:new)
          expect(Rails.logger).to have_received(:info).with("Browser push sent to #{user.email} with title #{notification.push_message_title}")
        end
      end

      it 'sends a fcm notification for firebase subscription' do
        with_modified_env ENABLE_PUSH_RELAY_SERVER: 'false', ONELINK_UPSTREAM_HUB_ENABLED: 'false' do
          create(:notification_subscription, user: notification.user, subscription_type: 'fcm')

          described_class.new(notification: notification).perform
          expect(Notification::FcmService).to have_received(:new)
          expect(fcm_double).to have_received(:send_v1)
          expect(WebPush).not_to have_received(:payload_send)
          expect(Rails.logger).to have_received(:info).with("FCM push sent to #{user.email} with title #{notification.push_message_title}")
        end
      end

      it 'opens the dialog of the person when the account uses communication threads' do
        with_modified_env VAPID_PUBLIC_KEY: 'test' do
          account.enable_features!('communication_threads')
          notification.reload.primary_actor.refresh_communication_thread!
          thread = notification.primary_actor.reload.communication_thread
          create(:notification_subscription, user: notification.user)

          described_class.new(notification: notification).perform

          expect(WebPush).to have_received(:payload_send).with(
            hash_including(message: a_string_including("/app/accounts/#{account.id}/communication_threads/#{thread.display_id}"))
          )
        end
      end

      it 'opens the conversation when the account does not use communication threads' do
        with_modified_env VAPID_PUBLIC_KEY: 'test' do
          create(:notification_subscription, user: notification.user)

          described_class.new(notification: notification).perform

          expect(WebPush).to have_received(:payload_send).with(
            hash_including(message: a_string_including("/app/accounts/#{account.id}/conversations/#{notification.conversation_display_id}"))
          )
        end
      end

      it 'uses the stored snapshot when the conversation has already been deleted' do
        with_modified_env VAPID_PUBLIC_KEY: 'test' do
          notification.primary_actor.destroy!
          create(:notification_subscription, user: notification.user)

          expect { described_class.new(notification: notification.reload).perform }.not_to raise_error
          expect(WebPush).to have_received(:payload_send)
        end
      end
    end
  end

  context 'when the push server returns error' do
    it 'sends webpush notifications for webpush subscription' do
      with_modified_env VAPID_PUBLIC_KEY: 'test' do
        mock_response = instance_double(Net::HTTPResponse, body: 'Subscription is invalid')
        mock_host = 'fcm.googleapis.com'

        allow(WebPush).to receive(:payload_send).and_raise(WebPush::InvalidSubscription.new(mock_response, mock_host))
        allow(Rails.logger).to receive(:info)

        create(:notification_subscription, :browser_push, user: notification.user)

        expect(Rails.logger).to receive(:info) do |message|
          expect(message).to include('WebPush subscription expired:')
        end

        described_class.new(notification: notification).perform
      end
    end
  end
end
