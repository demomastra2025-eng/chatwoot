class Webhooks::WhatsappEventsJob < MutexApplicationJob
  queue_as :whatsapp_inbound
  retry_on LockAcquisitionError, wait: 1.second, attempts: 8

  def perform(params = {}, options = {})
    hmac_verified = options.with_indifferent_access[:hmac_verified] == true
    channel = find_channel_from_whatsapp_business_payload(params)
    log_webhook_dispatch(channel, params)

    return log_inactive_channel(channel, params) if channel_is_inactive?(channel)
    return unless continue_after_account_update?(channel, params, hmac_verified)

    dispatch_message_payload(channel, message_dispatch_params(params))
  end

  # Detects if the webhook is an SMB message echo event (message sent from WhatsApp Business app)
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
  # Echo message payload (field: "smb_message_echoes"):
  # {
  #   "entry": [{
  #     "changes": [{
  #       "field": "smb_message_echoes",
  #       "value": {
  #         "message_echoes": [{ "from": "971545296927", "to": "919745786257", "id": "wamid...", "text": { "body": "Hi" } }]
  #       }
  #     }]
  #   }]
  # }
  #
  # Key differences:
  # - field: "smb_message_echoes" instead of "messages"
  # - message_echoes[] instead of messages[]
  # - "from" is the business number, "to" is the contact (reversed from regular messages)
  # - No "contacts" array in echo payload
  def message_echo_event?(params)
    params.dig(:entry, 0, :changes, 0, :field) == 'smb_message_echoes'
  end

  def log_inactive_channel(channel, params)
    phone_number = channel&.phone_number || "unknown - #{params[:phone_number]}"
    Rails.logger.warn("Inactive WhatsApp channel: #{phone_number}")
  end

  def continue_after_account_update?(channel, params, hmac_verified)
    return true unless account_update_event?(params)

    handle_account_updates(channel, params) if trusted_account_update?(channel, hmac_verified)
    non_account_update_event?(params)
  end

  def dispatch_message_payload(channel, params)
    if message_echo_event?(params)
      handle_message_echo(channel, params)
    else
      handle_message_events(channel, params)
    end
  end

  def account_update_event?(params)
    webhook_fields(params).include?('account_update')
  end

  def trusted_account_update?(channel, hmac_verified)
    return true if hmac_verified && channel.provider == 'whatsapp_cloud'

    Rails.logger.warn(
      "[WHATSAPP ACCOUNT UPDATE] ignored untrusted event channel=#{channel.id} " \
      "provider=#{channel.provider} hmac_verified=#{hmac_verified}"
    )
    false
  end

  def non_account_update_event?(params)
    webhook_fields(params).any? { |field| field != 'account_update' }
  end

  def message_dispatch_params(params)
    return params unless account_update_event?(params)

    payload = params.to_h.deep_dup.with_indifferent_access
    payload[:entry] = Array(payload[:entry]).filter_map do |entry|
      entry = entry.to_h.with_indifferent_access
      changes = Array(entry[:changes]).reject { |change| change.to_h.with_indifferent_access[:field] == 'account_update' }
      entry.merge(changes: changes) if changes.present?
    end
    payload
  end

  def handle_account_updates(callback_channel, params)
    account_update_channels(callback_channel, params).find_each do |channel|
      Whatsapp::AccountUpdateService.new(channel: channel, params: params).perform
    end
  end

  def account_update_channels(callback_channel, params)
    Channel::Whatsapp
      .where(account_id: callback_channel.account_id, provider: 'whatsapp_cloud')
      .where("provider_config ->> 'business_account_id' IN (?)", account_update_waba_ids(params))
  end

  def account_update_waba_ids(params)
    Array(params[:entry] || params['entry']).filter_map { |entry| entry[:id] || entry['id'] }.map(&:to_s).uniq
  end

  def handle_message_echo(channel, params)
    Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params, outgoing_echo: true).perform
  end

  def handle_message_events(channel, params)
    case channel.provider
    when 'whatsapp_cloud'
      Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params).perform
    else
      Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: params).perform
    end
  end

  private

  def channel_is_inactive?(channel)
    return true if channel.blank?
    return true unless channel.account.active?

    false
  end

  def find_channel_by_url_param(params)
    return unless params[:phone_number]

    Channel::Whatsapp.find_by(phone_number: params[:phone_number])
  end

  def find_channel_from_whatsapp_business_payload(params)
    # for the case where facebook cloud api support multiple numbers for a single app
    # https://github.com/chatwoot/chatwoot/issues/4712#issuecomment-1173838350
    # we will give priority to the phone_number in the payload
    if params[:object] == 'whatsapp_business_account'
      payload_channel = get_channel_from_wb_payload(params)
      return payload_channel if payload_channel.present?
      return find_channel_by_url_param(params) if account_update_event?(params)

      return nil
    end

    find_channel_by_url_param(params)
  end

  def get_channel_from_wb_payload(wb_params)
    phone_number = "+#{wb_params[:entry].first[:changes].first.dig(:value, :metadata, :display_phone_number)}"
    phone_number_id = wb_params[:entry].first[:changes].first.dig(:value, :metadata, :phone_number_id)
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)
    # validate to ensure the phone number id matches the whatsapp channel
    return channel if channel && channel.provider_config['phone_number_id'] == phone_number_id
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
