require 'rails_helper'

RSpec.describe Notification::PushTestService do
  let(:user) { create(:user) }
  let(:title) { 'OneLink push check' }
  let(:body) { 'Diagnostic push body' }

  def perform(subscription_ids, target_user: user)
    described_class.new(user: target_user, subscription_ids: subscription_ids, title: title, body: body).perform
  end

  describe '.default_title' do
    it 'uses the configured installation name' do
      allow(GlobalConfigService).to receive(:load).with('INSTALLATION_NAME', 'OneLink').and_return('CustomOneLink')

      expect(described_class.default_title).to eq('CustomOneLink notification test')
    end

    it 'falls back to OneLink when installation name is not configured' do
      allow(GlobalConfigService).to receive(:load).with('INSTALLATION_NAME', 'OneLink').and_return('OneLink')

      expect(described_class.default_title).to eq('OneLink notification test')
    end
  end

  describe '#perform' do
    let(:browser_subscription) do
      create(
        :notification_subscription,
        :browser_push,
        user: user,
        identifier: 'browser-endpoint-1',
        subscription_attributes: {
          'endpoint' => 'https://push.example.test/send/browser-token-tail',
          'p256dh' => 'p256dh-key',
          'auth' => 'auth-token'
        }
      )
    end

    let(:fcm_subscription) do
      create(
        :notification_subscription,
        :fcm,
        user: user,
        identifier: 'fcm-device-1',
        subscription_attributes: {
          'push_token' => 'fcm-token-tail',
          'device_id' => 'device-123456'
        }
      )
    end

    it 'only tests subscriptions owned by the selected user' do
      other_user_subscription = create(:notification_subscription, :fcm, identifier: 'other-device')

      expect(perform([other_user_subscription.id])).to eq([])
    end

    it 'skips browser push when VAPID keys are missing' do
      allow(VapidService).to receive(:public_key).and_return(nil)
      allow(WebPush).to receive(:payload_send)

      result = perform([browser_subscription.id]).first

      expect(result).to include(
        id: browser_subscription.id,
        type: 'browser_push',
        status: :skipped,
        message: 'VAPID keys not configured'
      )
      expect(result[:device]).to eq('push.example.test')
      expect(result[:token_tail]).to eq('…n-tail')
      expect(WebPush).not_to have_received(:payload_send)
    end

    it 'sends browser push with redacted diagnostics' do
      allow(VapidService).to receive(:public_key).and_return('public-key')
      allow(VapidService).to receive(:private_key).and_return('private-key')
      allow(WebPush).to receive(:payload_send)

      result = perform([browser_subscription.id]).first

      expect(WebPush).to have_received(:payload_send).with(
        hash_including(
          endpoint: 'https://push.example.test/send/browser-token-tail',
          p256dh: 'p256dh-key',
          auth: 'auth-token',
          vapid: hash_including(public_key: 'public-key', private_key: 'private-key')
        )
      )
      expect(result).to include(type: 'browser_push', status: :success, message: 'Web push accepted by endpoint')
      expect(result[:device]).to eq('push.example.test')
      expect(result[:token_tail]).to eq('…n-tail')
    end

    it 'uses OneLink frontend URL as browser push fallback' do
      allow(VapidService).to receive(:public_key).and_return('public-key')
      allow(VapidService).to receive(:private_key).and_return('private-key')
      allow(WebPush).to receive(:payload_send)

      with_modified_env FRONTEND_URL: nil do
        perform([browser_subscription.id])
      end

      expect(WebPush).to have_received(:payload_send).with(
        hash_including(
          message: include('https://app.one-link.kz'),
          vapid: hash_including(subject: 'https://app.one-link.kz')
        )
      )
    end

    it 'sends FCM directly when Firebase credentials are configured' do
      fcm_client = instance_double(FCM, send_v1: { status_code: 200, body: 'accepted fcm-token-tail' })
      fcm_service = instance_double(Notification::FcmService, fcm_client: fcm_client)
      allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return('firebase-project')
      allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS', nil).and_return('firebase-credentials')
      allow(Notification::FcmService).to receive(:new).with('firebase-project', 'firebase-credentials').and_return(fcm_service)

      result = perform([fcm_subscription.id]).first

      expect(fcm_client).to have_received(:send_v1).with(
        hash_including(
          token: 'fcm-token-tail',
          notification: { title: title, body: body },
          fcm_options: { analytics_label: 'SuperAdminTest' }
        )
      )
      expect(result).to include(type: 'fcm', status: :success, message: 'HTTP 200 — accepted …n-tail')
      expect(result[:message]).not_to include('fcm-token-tail')
      expect(result[:device]).to eq('…123456')
      expect(result[:token_tail]).to eq('…n-tail')
    end

    it 'sends FCM through ChatwootHub when Firebase credentials are absent and relay is enabled' do
      allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
      allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS', nil).and_return(nil)
      response = instance_double(RestClient::Response, code: 202, body: 'relay accepted for fcm-token-tail')
      allow(ChatwootHub).to receive(:send_push_with_response).and_return(response)

      with_modified_env ENABLE_PUSH_RELAY_SERVER: 'true' do
        result = perform([fcm_subscription.id]).first

        expect(ChatwootHub).to have_received(:send_push_with_response).with(
          hash_including(token: 'fcm-token-tail', notification: { title: title, body: body })
        )
        expect(result).to include(type: 'fcm_via_hub', status: :success, message: 'HTTP 202 — relay accepted for …n-tail')
        expect(result[:message]).not_to include('fcm-token-tail')
      end
    end

    it 'skips FCM when neither Firebase credentials nor relay are available' do
      allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
      allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS', nil).and_return(nil)

      with_modified_env ENABLE_PUSH_RELAY_SERVER: 'false' do
        result = perform([fcm_subscription.id]).first

        expect(result).to include(type: 'fcm', status: :skipped, message: 'No Firebase credentials and push relay disabled')
      end
    end
  end
end
