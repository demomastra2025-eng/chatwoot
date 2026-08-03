module Whatsapp::FacebookApiClientWebhookSubscriptionHelpers
  CALLBACK_OUTCOME_UNKNOWN_MESSAGE =
    'Webhook callback update outcome is unknown; preserving the local channel for recovery'.freeze

  def subscribe_waba_webhook(waba_id, callback_url, verify_token, subscribed_fields: webhook_subscribed_fields)
    state = subscription_state
    state[:already_subscribed] = app_subscribed_to_waba?(waba_id)
    subscribe_app_unless_present(waba_id, state)
    state[:remote_mutation_attempted] = true
    result = override_waba_callback(waba_id, callback_url, verify_token, subscribed_fields: subscribed_fields)
    verify_app_subscription!(waba_id)
    result
  rescue StandardError => e
    handle_subscription_error(state, e)
  end

  def app_subscribed_to_waba?(waba_id)
    response = HTTParty.get(
      "#{self.class::BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query
    )
    data = handle_response(response, 'WABA app subscriptions fetch failed')
    app_id = GlobalConfigService.load('WHATSAPP_APP_ID', '').to_s

    Array(data['data']).any? { |subscription| subscription.to_h['id'].to_s == app_id }
  end

  def subscribe_app_to_waba(waba_id)
    response = HTTParty.post(
      "#{self.class::BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query
    )

    handle_response(response, 'App subscription to WABA failed')
  end

  def override_waba_callback(waba_id, callback_url, verify_token, subscribed_fields: webhook_subscribed_fields)
    response = HTTParty.post(
      "#{self.class::BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query,
      body: {
        override_callback_uri: callback_url,
        verify_token: verify_token,
        subscribed_fields: subscribed_fields
      }.to_json
    )

    handle_response(response, 'Webhook callback override failed')
  end

  def unsubscribe_waba_webhook(waba_id)
    response = HTTParty.delete(
      "#{self.class::BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query
    )

    handle_response(response, 'Webhook unsubscription failed')
  end

  private

  def subscription_state
    { already_subscribed: false, remote_mutation_attempted: false }
  end

  def subscribe_app_unless_present(waba_id, state)
    return if state[:already_subscribed]

    state[:remote_mutation_attempted] = true
    subscribe_app_to_waba(waba_id)
  end

  def verify_app_subscription!(waba_id)
    return if app_subscribed_to_waba?(waba_id)

    raise 'Meta did not persist the WABA app subscription'
  end

  def handle_subscription_error(state, error)
    raise error unless state[:remote_mutation_attempted]

    raise Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError, CALLBACK_OUTCOME_UNKNOWN_MESSAGE
  end
end
