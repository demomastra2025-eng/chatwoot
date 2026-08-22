class Webhooks::WhatsappEventsJob < MutexApplicationJob
  include Webhooks::WhatsappLifecycleEventHelpers
  include Webhooks::WhatsappLegacyVerificationHelpers

  MESSAGE_ECHO_FIELDS = %w[message_echoes smb_message_echoes].freeze

  queue_as :whatsapp_inbound
  retry_on LockAcquisitionError, wait: 1.second, attempts: 8
  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 5.seconds, attempts: :unlimited
  retry_on Whatsapp::AuthenticatedWebhookRoute::RuntimeIdentityChangedError, Whatsapp::CloudMediaDownload::MetadataFetchError, Down::Error,
           Whatsapp::IncomingMessageWhatsappCloudService::PreparedAttachmentError, wait: 5.seconds, attempts: 8
  retry_on Whatsapp::IncomingMessageMutationService::TargetNotFoundError, wait: 5.seconds, attempts: 120

  def perform(params = {}, options = {})
    dispatch_changes(params, options.with_indifferent_access)
  end

  def dispatch_changes(params, verification_context)
    webhook_payloads(params).each do |payload|
      channel = find_channel_from_whatsapp_business_payload(payload)
      log_webhook_dispatch(channel, payload)
      route_context = verification_context_for(channel, payload, verification_context)
      dispatch_authenticated_change(channel, payload, route_context)
    end
  end

  def dispatch_authenticated_change(channel, payload, verification_context)
    Whatsapp::AuthenticatedMediaWebhookDispatch.new(
      channel: channel,
      payload: payload,
      verification_context: verification_context,
      live_priority_token: job_id,
      outgoing_echo: message_echo_event?(payload),
      dispatch_action: lambda do |prepared_attachment|
        dispatch_change(channel, payload, verification_context[:hmac_verified] == true, prepared_attachment: prepared_attachment)
      end
    ).perform
  end

  def webhook_payloads(params)
    Whatsapp::WebhookBatchNormalizer.new(params: params).perform
  end

  def dispatch_change(channel, payload, hmac_verified, prepared_attachment: nil)
    field = webhook_fields(payload).first
    if field == 'account_update'
      handle_account_updates(payload) if trusted_account_update?(channel, hmac_verified)
      return
    end

    if Whatsapp::LifecycleWebhookService::FIELDS.include?(field)
      handle_lifecycle_updates(channel, field, payload) if trusted_lifecycle_update?(channel, hmac_verified)
      return
    end

    return if log_inactive_payload?(channel, payload)

    dispatch_non_account_change(channel, payload, prepared_attachment: prepared_attachment)
  end

  def log_inactive_payload?(channel, payload)
    return false unless channel_is_inactive?(channel)

    log_inactive_channel(channel, payload)
    true
  end

  def dispatch_non_account_change(channel, payload, prepared_attachment: nil)
    case webhook_fields(payload).first
    when 'history', 'smb_app_state_sync'
      enqueue_coexistence_sync(channel, webhook_fields(payload).first, payload)
    else
      dispatch_message_payload(channel, payload, prepared_attachment: prepared_attachment)
    end
  end

  def coexistence_field?(payload)
    %w[history smb_app_state_sync].include?(webhook_fields(payload).first)
  end

  def change_value(params)
    params.dig(:entry, 0, :changes, 0, :value).to_h.with_indifferent_access
  end

  def enqueue_coexistence_sync(channel, field, params)
    routing_context = Whatsapp::WebhookChannelResolver.new(params: params).routing_context
    coexistence_channels(channel, params).each do |coexistence_channel|
      channel_context = routing_context.merge(
        sync_generation: coexistence_channel.provider_config.dig('coexistence_sync', 'generation')
      )
      provider_event_at = params.dig(:entry, 0, :time)
      channel_context[:provider_event_at] = provider_event_at if provider_event_at.present?
      Whatsapp::CoexistenceWebhookSyncJob.perform_later(
        coexistence_channel.id,
        field,
        change_value(params).to_h,
        channel_context
      )
    end
  end

  def coexistence_channels(channel, params)
    resolved_channel = Whatsapp::WebhookChannelResolver.new(params: params).perform
    return Channel::Whatsapp.none if channel.blank? || resolved_channel.blank?
    return Channel::Whatsapp.none unless resolved_channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'

    Channel::Whatsapp.active_cloud.where(id: resolved_channel.id)
  end

  # Detects if the webhook is a message echo event (message sent from WhatsApp Business app)
  # This is part of WhatsApp coexistence feature where businesses can respond from both
  # Chatwoot and the WhatsApp Business app, with messages synced to Chatwoot.
  #
  # Regular message payload (field: "messages"):
  # {
  #   "entry": [{
  #     "changes": [{
  #       "field": "messages",
  #       "value": {
  #         "contacts": [{ "wa_id": "919745786257", "profile": { "name": "Customer" } }],
  #         "messages": [{ "from": "919745786257", "id": "wamid...", "text": { "body": "Hello" } }]
  #       }
  #     }]
  #   }]
  # }
  #
  # Echo message payload (field: "message_echoes" or legacy "smb_message_echoes"):
  # {
  #   "entry": [{
  #     "changes": [{
  #       "field": "message_echoes",
  #       "value": {
  #         "message_echoes": [{ "from": "971545296927", "to": "919745786257", "id": "wamid...", "text": { "body": "Hi" } }]
  #       }
  #     }]
  #   }]
  # }
  #
  # Key differences:
  # - field: "message_echoes" (or legacy "smb_message_echoes") instead of "messages"
  # - message_echoes[] instead of messages[]
  # - "from" is the business number, "to" is the contact (reversed from regular messages)
  # - No "contacts" array in echo payload
  def message_echo_event?(params)
    MESSAGE_ECHO_FIELDS.include?(params.dig(:entry, 0, :changes, 0, :field))
  end

  def log_inactive_channel(channel, params)
    phone_number = channel&.phone_number || "unknown - #{params[:phone_number]}"
    Rails.logger.warn("Inactive WhatsApp channel: #{phone_number}")
  end

  def dispatch_message_payload(channel, params, prepared_attachment: nil)
    if message_echo_event?(params)
      handle_message_echo(channel, params, prepared_attachment: prepared_attachment)
    else
      handle_message_events(channel, params, prepared_attachment: prepared_attachment)
    end
  end

  def account_update_event?(params)
    webhook_fields(params).include?('account_update')
  end

  def trusted_account_update?(channel, hmac_verified)
    return true if hmac_verified && (channel.blank? || channel.provider == 'whatsapp_cloud')

    Rails.logger.warn(
      "[WHATSAPP ACCOUNT UPDATE] ignored untrusted event channel=#{channel&.id || 'none'} " \
      "provider=#{channel&.provider || 'none'} hmac_verified=#{hmac_verified}"
    )
    false
  end

  def handle_account_updates(params)
    account_update_channels(params).find_each do |channel|
      Whatsapp::AccountUpdateService.new(channel: channel, params: params).perform
    end
  end

  def account_update_channels(params)
    Whatsapp::AccountUpdateChannelResolver.new(waba_ids: account_update_waba_ids(params)).resolve
  end

  def account_update_waba_ids(params)
    Array(params[:entry] || params['entry']).filter_map { |entry| entry[:id] || entry['id'] }.map(&:to_s).uniq
  end

  def handle_message_echo(channel, params, prepared_attachment: nil)
    Whatsapp::IncomingWebhookMessageDispatch.new(
      channel: channel, params: params, outgoing_echo: true, prepared_attachment: prepared_attachment
    ).perform
  end

  def handle_message_events(channel, params, prepared_attachment: nil)
    Whatsapp::IncomingWebhookMessageDispatch.new(
      channel: channel, params: params, prepared_attachment: prepared_attachment
    ).perform
  end

  private

  def channel_is_inactive?(channel)
    return true if channel.blank?
    return true unless channel.account.active?
    return true if channel.inbox.blank? || channel.inbox.deleting_at.present?

    false
  end

  def find_channel_from_whatsapp_business_payload(params)
    Whatsapp::WebhookRouteResolver.new(params: params).perform
  end

  def log_webhook_dispatch(channel, params)
    details = webhook_dispatch_details(channel, params)
    Rails.logger.info("[WHATSAPP_WEBHOOK] dispatch #{details.map { |key, value| "#{key}=#{value}" }.join(' ')}")
  end

  def webhook_dispatch_details(channel, params)
    details = {
      phone_number: params[:phone_number] || params['phone_number'],
      channel_id: 'none',
      account_id: 'none',
      inbox_id: 'none',
      provider: 'none',
      fields: webhook_fields(params).join(','),
      echo: message_echo_event?(params)
    }
    return details if channel.blank?

    details.merge(
      phone_number: channel.phone_number,
      channel_id: channel.id,
      account_id: channel.account_id,
      inbox_id: channel.inbox&.id || 'none',
      provider: channel.provider
    )
  end

  def webhook_fields(params)
    Array(params[:entry] || params['entry']).flat_map do |entry|
      Array(entry[:changes] || entry['changes']).filter_map do |change|
        change[:field] || change['field']
      end
    end.uniq
  end
end

Webhooks::WhatsappEventsJob.prepend_mod_with('Webhooks::WhatsappEventsJob')
