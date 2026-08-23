class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern
  include WhatsappWebhookAuthenticationConcern
  include WhatsappWebhookForwardingConcern

  before_action :verify_meta_signature!, only: :process_payload
  before_action :verify_forwarded_delivery!, only: :process_payload

  def process_payload
    log_webhook_request

    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{request.path_parameters[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_content
      return
    end

    Whatsapp::WebhookIngressDispatcher.new(
      payload: job_params,
      central_ingress: central_ingress_callback?,
      default_callback: default_callback?,
      verification_context: method(:routing_verification_context)
    ).perform
    head :ok
  end

  private

  def default_callback?
    request.path_parameters[:phone_number].blank?
  end

  def central_ingress_callback?
    default_callback? && request.query_parameters['channel_id'].blank? && !forwarded_delivery?
  end

  def webhook_matches_channel_waba?(channel)
    return true if channel.blank?

    webhook_routing_identity_present? && webhook_waba_ids_match?(channel) && webhook_phone_ids_match?(channel) &&
      webhook_display_phones_match?(channel)
  end

  def webhook_routing_identity_present?
    webhook_waba_ids.present? || webhook_phone_number_ids.present? || webhook_display_phone_numbers.present?
  end

  def webhook_waba_ids_match?(channel)
    webhook_waba_ids.empty? ||
      (webhook_waba_ids.one? && webhook_waba_ids.first == channel.provider_config.to_h['business_account_id'].to_s)
  end

  def webhook_phone_ids_match?(channel)
    webhook_phone_number_ids.empty? || webhook_phone_number_ids.all?(channel.provider_config.to_h['phone_number_id'].to_s)
  end

  def webhook_display_phones_match?(channel)
    webhook_display_phone_numbers.empty? || webhook_display_phone_numbers.all?(channel.phone_number.to_s)
  end

  def webhook_phone_number_ids
    @webhook_phone_number_ids ||= webhook_changes.filter_map do |change|
      change.dig(:value, :metadata, :phone_number_id).presence
    end.map(&:to_s).uniq
  end

  def webhook_display_phone_numbers
    @webhook_display_phone_numbers ||= webhook_changes.filter_map do |change|
      normalized_phone_number(change.dig(:value, :metadata, :display_phone_number))
    end.uniq
  end

  def webhook_waba_ids
    @webhook_waba_ids ||= webhook_entries.filter_map { |entry| entry[:id].presence }.map(&:to_s).uniq
  end

  def whatsapp_channel
    @whatsapp_channel ||= channel_from_path || whatsapp_business_payload_channel
  end

  def channel_from_path
    phone_number = request.path_parameters[:phone_number]
    Channel::Whatsapp.find_by(phone_number: phone_number) if phone_number.present?
  end

  def meta_signature_verification_required?
    return true if request.path_parameters[:phone_number].blank?
    return true if whatsapp_channel.blank?

    whatsapp_channel.provider == 'whatsapp_cloud'
  end

  def whatsapp_business_payload_channel
    return unless params[:object] == 'whatsapp_business_account'

    metadata = webhook_changes.filter_map { |change| change.dig(:value, :metadata) }.first
    channel = channel_from_webhook_metadata(metadata) if metadata.present?
    return channel if channel.present?

    channel_from_waba_entry_ids
  end

  def webhook_changes
    webhook_entries.flat_map { |entry| Array(entry[:changes]) }
  end

  def webhook_entries
    Array(params[:entry]).map { |entry| entry.to_unsafe_h.with_indifferent_access }
  end

  def channel_from_waba_entry_ids
    waba_ids = webhook_entries.filter_map { |entry| entry[:id] }.map(&:to_s).uniq
    return if waba_ids.empty?

    owner_account_id = Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_ids)
    return if owner_account_id.blank?

    channels = Channel::Whatsapp.active_cloud.for_waba(waba_ids).where(account_id: owner_account_id).limit(2).to_a
    channels.one? ? channels.first : nil
  end

  def channel_from_webhook_metadata(metadata)
    phone_number = normalized_phone_number(metadata[:display_phone_number])
    phone_number_id = metadata[:phone_number_id]
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)

    return channel if channel&.provider == 'whatsapp_cloud' && channel.provider_config['phone_number_id'] == phone_number_id
  end

  def normalized_phone_number(phone_number)
    return if phone_number.blank?

    phone_number = phone_number.to_s
    phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
  end

  def job_params
    job_params = params.to_unsafe_hash
    route_phone_number = request.path_parameters[:phone_number]
    if route_phone_number.present?
      job_params['phone_number'] = route_phone_number
    else
      job_params.delete('phone_number')
    end
    job_params
  end

  def routing_verification_context(payload = job_params)
    return waba_scoped_verification_context(payload) if default_callback?

    {
      hmac_verified: meta_signature_verified?,
      channel_id: whatsapp_channel&.id,
      channel_identity: Whatsapp::AuthenticatedWebhookRoute.identity_snapshot(whatsapp_channel, request.path_parameters[:phone_number]),
      waba_account_ids: authenticated_waba_account_ids
    }
  end

  def waba_scoped_verification_context(payload = job_params)
    {
      hmac_verified: meta_signature_verified?,
      channel_id: nil,
      channel_identity: {},
      waba_account_ids: authenticated_waba_account_ids(payload_waba_ids(payload)),
      waba_scoped: true
    }
  end

  def authenticated_waba_account_ids(waba_ids = webhook_waba_ids)
    waba_ids.index_with do |waba_id|
      Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_id)
    end
  end

  def payload_waba_ids(payload)
    Array(payload.to_h.with_indifferent_access[:entry]).filter_map do |entry|
      entry.to_h.with_indifferent_access[:id].to_s.presence
    end.uniq
  end

  def inactive_whatsapp_number?
    phone_number = request.path_parameters[:phone_number]
    return false if phone_number.blank?

    inactive_numbers = GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s
    return false if inactive_numbers.blank?

    inactive_numbers_array = inactive_numbers.split(',').map(&:strip)
    inactive_numbers_array.include?(phone_number)
  end

  def log_webhook_request
    changes = webhook_changes
    values = changes.filter_map { |change| change[:value] || change['value'] }
    fields = changes.filter_map { |change| change[:field] || change['field'] }.uniq

    Rails.logger.info(webhook_log_parts(changes, values, fields).join(' '))
  end

  def webhook_log_parts(changes, values, fields)
    [
      '[WHATSAPP_WEBHOOK] received',
      "request_id=#{request.request_id}",
      "phone_number=#{request.path_parameters[:phone_number]}",
      "object=#{params[:object] || 'unknown'}",
      "entries=#{Array(params[:entry]).size}",
      "changes=#{changes.size}",
      "fields=#{fields.join(',')}",
      "messages=#{webhook_value_count(values, :messages)}",
      "statuses=#{webhook_value_count(values, :statuses)}",
      "contacts=#{webhook_value_count(values, :contacts)}",
      "echoes=#{webhook_value_count(values, :message_echoes)}"
    ]
  end

  def webhook_value_count(values, key)
    values.sum { |value| Array(value[key] || value[key.to_s]).size }
  end
end
