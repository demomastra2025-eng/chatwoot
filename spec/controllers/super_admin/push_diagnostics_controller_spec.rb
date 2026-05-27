require 'rails_helper'

RSpec.describe 'Super Admin Push Diagnostics', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:user) { create(:user, email: 'operator@example.test', name: 'Operator User') }

  describe 'GET /super_admin/push_diagnostics' do
    it 'redirects unauthenticated users' do
      get '/super_admin/push_diagnostics'

      expect(response).to have_http_status(:redirect)
    end

    it 'shows a user subscriptions page with redacted device identifiers' do
      create(
        :notification_subscription,
        :fcm,
        user: user,
        identifier: 'operator-device',
        subscription_attributes: { 'device_id' => 'device-abcdef', 'push_token' => 'push-token-123456' }
      )
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/push_diagnostics', params: { user_query: user.email }

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Operator User')
      expect(response.body).to include('operator@example.test')
      expect(response.body).to include('…abcdef')
      expect(response.body).to include('…123456')
      expect(response.body).not_to include('push-token-123456')
    end
  end

  describe 'POST /super_admin/push_diagnostics' do
    it 'redirects when no subscriptions are selected' do
      sign_in(super_admin, scope: :super_admin)

      post '/super_admin/push_diagnostics', params: { user_id: user.id }

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(super_admin_push_diagnostics_path(user_query: user.id))
      expect(flash[:alert]).to eq(I18n.t('super_admin.push_diagnostics.no_subscriptions_to_test'))
    end

    it 'runs push diagnostics only through the service' do
      subscription = create(:notification_subscription, :fcm, user: user, identifier: 'operator-device')
      service = instance_double(Notification::PushTestService, perform: [{ id: subscription.id, type: 'fcm', status: :success, message: 'ok' }])
      allow(Notification::PushTestService).to receive(:new).and_return(service)
      sign_in(super_admin, scope: :super_admin)

      post '/super_admin/push_diagnostics', params: {
        user_id: user.id,
        subscription_ids: [subscription.id],
        push_title: 'Test title',
        push_body: 'Test body'
      }

      expect(response).to have_http_status(:success)
      expect(Notification::PushTestService).to have_received(:new).with(
        user: user,
        subscription_ids: [subscription.id],
        title: 'Test title',
        body: 'Test body'
      )
      expect(response.body).to include('ok')
    end
  end

  describe 'POST /super_admin/push_diagnostics/destroy_subscriptions' do
    it 'deletes selected subscriptions scoped to the selected user' do
      own_subscription = create(:notification_subscription, :fcm, user: user, identifier: 'own-device')
      other_subscription = create(:notification_subscription, :fcm, identifier: 'other-device')
      sign_in(super_admin, scope: :super_admin)

      post '/super_admin/push_diagnostics/destroy_subscriptions', params: {
        user_id: user.id,
        subscription_ids: [own_subscription.id, other_subscription.id]
      }

      expect(response).to redirect_to(super_admin_push_diagnostics_path(user_query: user.id))
      expect(NotificationSubscription.exists?(own_subscription.id)).to be(false)
      expect(NotificationSubscription.exists?(other_subscription.id)).to be(true)
      expect(flash[:notice]).to eq(I18n.t('super_admin.push_diagnostics.subscriptions_deleted', count: 1))
    end
  end
end
