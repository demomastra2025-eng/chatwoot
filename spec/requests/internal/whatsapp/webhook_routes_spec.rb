require 'rails_helper'

RSpec.describe 'Internal WhatsApp webhook routes' do
  let(:path) { '/internal/whatsapp/webhook_routes' }
  let(:secret) { 'dev-route-secret' }
  let(:payload) do
    { waba_id: '123456', phone_number_id: '987654', destination: 'dev' }
  end

  around do |example|
    with_modified_env(
      WHATSAPP_WEBHOOK_ROUTE_REGISTRY_SECRETS: JSON.generate(dev: secret, widget: 'widget-route-secret')
    ) { example.run }
  end

  it 'idempotently registers and removes an exact route' do
    current_token = nil
    route_inserts = capture_route_inserts do
      put path, params: body, headers: signed_headers(:put, body)
      expect(response).to have_http_status(:created)
      first_token = response.headers.fetch('X-OneLink-Route-Registration-Token')

      put path, params: body, headers: signed_headers(:put, body)
      expect(response).to have_http_status(:no_content)
      current_token = response.headers.fetch('X-OneLink-Route-Registration-Token')
      expect(current_token).to eq(first_token)
    end

    expect(route_inserts.one?).to be(true)

    current_delete_body = JSON.generate(payload.merge(registration_token: current_token))
    delete path, params: current_delete_body, headers: signed_headers(:delete, current_delete_body)
    expect(response).to have_http_status(:no_content)
    expect(WhatsappWebhookRoute.where(payload)).to be_empty

    delete path, params: current_delete_body, headers: signed_headers(:delete, current_delete_body)
    expect(response).to have_http_status(:no_content)
  end

  it 'rejects a stale registration generation without removing the current route' do
    WhatsappWebhookRoute.create!(payload.merge(registration_token: SecureRandom.uuid))
    stale_delete_body = JSON.generate(payload.merge(registration_token: SecureRandom.uuid))

    delete path, params: stale_delete_body, headers: signed_headers(:delete, stale_delete_body)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq('error' => 'stale_registration_token')
    expect(WhatsappWebhookRoute.where(payload)).to exist
  end

  it 'backfills a missing registration token without attempting another insert' do
    route = WhatsappWebhookRoute.create!(payload)
    route_inserts = capture_route_inserts do
      put path, params: body, headers: signed_headers(:put, body)
    end

    expect(response).to have_http_status(:no_content)
    expect(response.headers.fetch('X-OneLink-Route-Registration-Token')).to match(WhatsappWebhookRoute::REGISTRATION_TOKEN)
    expect(route.reload.registration_token).to eq(response.headers.fetch('X-OneLink-Route-Registration-Token'))
    expect(route_inserts).to be_empty
  end

  it 'serializes route mutation with canonical ingress for the whole WABA' do
    expect(WhatsappWebhookRoute).to receive(:with_waba_registry_lock).with('123456').and_call_original

    put path, params: body, headers: signed_headers(:put, body)

    expect(response).to have_http_status(:created)
  end

  it 'rejects legacy unconditional deletion without removing the current route generation' do
    WhatsappWebhookRoute.create!(payload.merge(registration_token: SecureRandom.uuid))

    delete path, params: body, headers: signed_headers(:delete, body)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq('error' => 'registration_token_required')
    expect(WhatsappWebhookRoute.where(payload)).to exist
  end

  it 'refuses to override a locally owned PROD phone' do
    allow(WhatsappWebhookRoute).to receive(:local_prod_owner_exists?)
      .with('123456', '987654').and_return(true)

    put path, params: body, headers: signed_headers(:put, body)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq('error' => 'local_prod_owner')
    expect(WhatsappWebhookRoute.where(payload)).to be_empty
  end

  it 'binds the signature to the HTTP method' do
    WhatsappWebhookRoute.create!(payload)

    delete path, params: body, headers: signed_headers(:put, body)

    expect(response).to have_http_status(:unauthorized)
    expect(WhatsappWebhookRoute.where(payload)).to exist
  end

  it 'rejects a signature made with another destination secret' do
    put path, params: body, headers: signed_headers(:put, body, signing_secret: 'widget-route-secret')

    expect(response).to have_http_status(:unauthorized)
    expect(WhatsappWebhookRoute.where(payload)).to be_empty
  end

  it 'rejects a stale request timestamp' do
    timestamp = 10.minutes.ago.to_i.to_s
    put path, params: body, headers: signed_headers(:put, body, timestamp: timestamp)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects non-numeric provider identifiers' do
    invalid_body = JSON.generate(payload.merge(waba_id: 'not-a-waba'))
    put path, params: invalid_body, headers: signed_headers(:put, invalid_body)

    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects an unsigned or malformed compensation token' do
    invalid_body = JSON.generate(payload.merge(registration_token: 'not-a-token'))

    delete path, params: invalid_body, headers: signed_headers(:delete, invalid_body)

    expect(response).to have_http_status(:bad_request)
  end

  def body
    @body ||= JSON.generate(payload)
  end

  def capture_route_inserts(&)
    inserts = []
    callback = lambda do |*args|
      sql = ActiveSupport::Notifications::Event.new(*args).payload[:sql].to_s
      inserts << sql if sql.start_with?('INSERT INTO "whatsapp_webhook_routes"')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    inserts
  end

  def signed_headers(method, request_body, timestamp: Time.now.to_i.to_s, signing_secret: secret)
    {
      'CONTENT_TYPE' => 'application/json',
      'X-OneLink-Route-Timestamp' => timestamp,
      'X-OneLink-Route-Signature' => Whatsapp::WebhookRouteRegistryClient.signature(
        secret: signing_secret,
        method: method,
        destination: payload.fetch(:destination),
        timestamp: timestamp,
        body: request_body
      )
    }
  end
end
