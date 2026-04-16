class WhatsappWeb::Providers::EvolutionService < WhatsappWeb::Providers::BaseService
  EVOLUTION_INTEGRATION = 'WHATSAPP-BAILEYS'.freeze
  MEDIA_UNAVAILABLE_STATUSES = [403, 404, 410].freeze
  ECHO_JOB_CLASSES = [
    Channels::WhatsappWeb::OutgoingEchoJob.name,
    Channels::WhatsappWeb::MessageUpdateBackfillJob.name
  ].freeze
  DEFAULT_EVENTS = %w[
    QRCODE_UPDATED
    CONNECTION_UPDATE
    STATUS_INSTANCE
    LOGOUT_INSTANCE
    REMOVE_INSTANCE
    CALL
    MESSAGES_UPSERT
    MESSAGES_EDITED
    MESSAGES_UPDATE
    MESSAGES_DELETE
    SEND_MESSAGE
    SEND_MESSAGE_UPDATE
    CONTACTS_UPSERT
    CONTACTS_UPDATE
    LABELS_EDIT
    LABELS_ASSOCIATION
    MESSAGING_HISTORY_SET
  ].freeze

  class RequestError < StandardError
    attr_reader :status, :body

    def initialize(message, status:, body:)
      super(message)
      @status = status
      @body = body
    end
  end

  def provision!
    existing_instance = instance_exists?

    if existing_instance
      repair!
      return channel
    end

    create_remote_instance!
  rescue RequestError => e
    if e.status == 403
      repair!
      return channel
    end

    if existing_instance && stale_runtime_recovery_candidate?(e)
      Rails.logger.warn(
        "[WHATSAPP WEB] Repair failed against existing Evolution instance #{channel.instance_name}; " \
        "forcing remote recreate after #{e.status}"
      )
      return recreate_remote_instance_after_failed_repair!
    end

    raise
  end

  def refresh_qr!
    response = request(:get, "/instance/connect/#{channel.instance_name}?number=#{channel.pairing_number}")
    sync_from_runtime_response!(response)
    channel
  rescue RequestError => e
    raise unless e.status == 404

    provision!
  end

  def reconnect!
    sync_connection_state!

    if restart_runtime_session_after_reconnect?
      restart_runtime_session!(force_refresh: true)
    else
      refresh_qr!
    end

    apply_runtime_configuration!
    channel
  end

  def disconnect!
    request(:delete, "/instance/logout/#{channel.instance_name}")
    channel.update!(
      lifecycle_state: 'disconnected',
      connection_state: 'close',
      qr_code: {},
      last_error: nil,
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  rescue RequestError => e
    raise unless e.status == 400

    channel.update!(
      lifecycle_state: 'disconnected',
      connection_state: 'close',
      qr_code: {},
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  end

  def repair!
    apply_runtime_configuration!
    sync_connection_state!
    refresh_qr! if qr_refresh_required_after_repair?
    channel
  rescue RequestError => e
    raise unless e.status == 404

    provision!
  end

  def sync_connection_state!
    response = request(:get, "/instance/connectionState/#{channel.instance_name}")
    state = response.dig('instance', 'state')
    normalized_state = normalized_connection_state(state)
    lifecycle_state = lifecycle_state_for(state, channel.qr_code.present?)
    clear_auth_artifacts = normalized_state == 'open'

    attributes = {
      connection_state: normalized_state,
      lifecycle_state: lifecycle_state,
      last_error: runtime_error_for_state(normalized_state, channel.last_error),
      last_synced_at: Time.current
    }
    if clear_auth_artifacts
      attributes[:qr_code] = {}
      attributes[:sync_state] = channel.sync_state_payload.merge('qr_generated_at' => nil)
    end

    channel.update!(attributes)
    request_history_sync_if_provider_ready if normalized_state == 'open'
  rescue RequestError => e
    raise unless e.status == 404

    channel.update!(
      connection_state: 'unknown',
      lifecycle_state: 'failed',
      last_error: 'Evolution instance not found',
      last_synced_at: Time.current
    )
  end

  def diagnostics
    echo_jobs = pending_echo_jobs_snapshot
    provisional_contacts = inbox.contacts.where(phone_number: [nil, ''])

    {
      counts: {
        messages_missing_provider_message_id: inbox.messages.where(source_id: [nil, '']).count,
        conversations_missing_provider_conversation_id: inbox.conversations.joins(:contact_inbox)
                                                             .where(contact_inboxes: { source_id: [nil, ''] }).count,
        provisional_contacts: provisional_contacts.count,
        echo_jobs_backlog: echo_jobs[:backlog],
        messages_update_without_local_source_id_hit_count: channel.sync_state_payload['echo_status_miss_count'].to_i
      },
      runtime: {
        oldest_pending_echo_job_at: echo_jobs[:oldest_pending_at]&.iso8601
      },
      samples: {
        provisional_contacts: provisional_contacts.limit(5).map do |contact|
          attrs = (contact.additional_attributes || {}).with_indifferent_access
          {
            id: contact.id,
            name: contact.name,
            identifier: contact.identifier,
            raw_jid: attrs[:raw_jid],
            canonical_jid: attrs[:canonical_jid]
          }
        end
      }
    }
  end

  def fetch_contacts(page: 1, offset: 100)
    request(:post, "/chat/findContacts/#{channel.instance_name}", body: {
              page: page,
              offset: offset,
              where: {}
            })
  end

  def fetch_messages(page: 1, offset: 100, from: nil, to: Time.current)
    body = {
      page: page,
      offset: offset,
      where: {
        key: {}
      }
    }

    if from.present?
      body[:where][:messageTimestamp] = {
        gte: from.iso8601,
        lte: to.iso8601
      }
    end

    request(:post, "/chat/findMessages/#{channel.instance_name}", body: body)
  end

  def fetch_chats(page: 1, offset: 100)
    request(:post, "/chat/findChats/#{channel.instance_name}", body: {
              page: page,
              offset: offset,
              where: {}
            })
  end

  def fetch_message_by_source_id(source_id:, remote_jid: nil, from_me: true)
    response = request(:post, "/chat/findMessages/#{channel.instance_name}", body: {
                         page: 1,
                         offset: 1,
                         where: {
                           key: {
                             id: source_id,
                             fromMe: from_me
                           }.tap do |key|
                             key[:remoteJid] = remote_jid if remote_jid.present?
                           end
                         }
                       })

    response.dig('messages', 'records', 0)
  end

  def fetch_message_media(record:, convert_to_mp4: false)
    request(:post, "/chat/getBase64FromMediaMessage/#{channel.instance_name}", body: {
              message: record,
              convertToMp4: convert_to_mp4
            }).deep_symbolize_keys
  rescue RequestError => e
    raise unless MEDIA_UNAVAILABLE_STATUSES.include?(e.status)

    {
      unavailable: true,
      status: e.status,
      error: e.message
    }
  end

  def prefer_provider_media_for_history?
    true
  end

  def fetch_labels
    request(:get, "/label/findLabels/#{channel.instance_name}")
  end

  def send_message(message)
    attachment = message.attachments.first

    response = if attachment&.location?
                 request(:post, "/message/sendLocation/#{channel.instance_name}", body: location_payload(message, attachment))
               elsif attachment.present?
                 request(:post, "/message/sendMedia/#{channel.instance_name}", body: media_payload(message, attachment))
               else
                 request(:post, "/message/sendText/#{channel.instance_name}", body: text_payload(message))
               end

    response.dig('key', 'id') || response.dig('data', 'key', 'id')
  end

  def update_message(message:, content:)
    source_id = message.source_id.to_s.presence
    remote_jid = normalized_remote_jid(message_remote_jid(message))
    raise ArgumentError, 'Message source_id is required for WhatsApp Web edits' if source_id.blank?
    raise ArgumentError, 'Conversation remote JID is required for WhatsApp Web edits' if remote_jid.blank?

    request(:post, "/chat/updateMessage/#{channel.instance_name}", body: {
              number: remote_jid,
              text: content.to_s,
              key: {
                id: source_id,
                fromMe: true,
                remoteJid: remote_jid
              }
            })
  end

  def mark_messages_read(messages:)
    read_messages = Array.wrap(messages).filter_map do |message|
      payload = message.respond_to?(:to_h) ? message.to_h.with_indifferent_access : {}
      source_id = payload[:id].to_s.presence
      remote_jid = normalized_remote_jid(payload[:remoteJid] || payload[:remote_jid])
      next if source_id.blank? || remote_jid.blank?

      {
        remoteJid: remote_jid,
        fromMe: ActiveModel::Type::Boolean.new.cast(extract_from_me(payload)),
        id: source_id
      }
    end

    return if read_messages.blank?

    request(:post, "/chat/markMessageAsRead/#{channel.instance_name}", body: {
              readMessages: read_messages
            })
  end

  def destroy_remote_instance!
    request(:delete, "/instance/delete/#{channel.instance_name}")
  rescue RequestError => e
    raise unless e.status == 404
  end

  private

  def instance_exists?
    request(:get, "/instance/connectionState/#{channel.instance_name}")
    true
  rescue RequestError => e
    return false if e.status == 404

    raise
  end

  def sync_from_runtime_response!(response)
    qr_payload = normalized_qr_payload(response)
    runtime_status = response.dig('instance', 'status') || response['status']
    runtime_state = response.dig('instance', 'state') || runtime_status
    runtime_error = runtime_error_message(response)

    runtime_state = 'close' if runtime_status.to_s == 'reauth_required' && qr_payload.blank?

    if qr_payload.blank? && runtime_state.blank? && runtime_error.present?
      channel.update!(
        connection_state: 'refused',
        lifecycle_state: 'failed',
        qr_code: {},
        last_error: runtime_error,
        last_synced_at: Time.current,
        sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
      )
      return
    end

    runtime_state ||= qr_payload.present? ? 'connecting' : nil
    normalized_state = normalized_connection_state(runtime_state)

    attributes = {
      connection_state: normalized_state,
      lifecycle_state: lifecycle_state_for(runtime_state, qr_payload.present?),
      last_error: runtime_error_for_state(normalized_state, runtime_error),
      last_synced_at: Time.current
    }

    if qr_payload.present?
      attributes[:qr_code] = qr_payload
      attributes[:sync_state] = channel.sync_state_payload.merge(
        'qr_generated_at' => Time.current.iso8601
      )
    elsif %w[open reconnecting close refused].include?(attributes[:connection_state])
      attributes[:qr_code] = {}
      attributes[:sync_state] = channel.sync_state_payload.merge('qr_generated_at' => nil)
    end

    channel.update!(attributes)
    request_history_sync_if_provider_ready if attributes[:connection_state] == 'open'
  end

  def create_remote_instance!
    response = request(:post, '/instance/create', body: create_payload)
    apply_runtime_configuration!
    sync_from_runtime_response!(response)
    channel
  end

  def recreate_remote_instance_after_failed_repair!
    destroy_remote_instance!
    create_remote_instance!
  end

  def stale_runtime_recovery_candidate?(error)
    error.status == 500
  end

  def request_history_sync_if_provider_ready
    return unless channel.history_sync_enabled?
    return if channel.provider_history_synced_at.blank?
    return if channel.full_history_baseline_current?

    mode = channel.preferred_history_sync_mode
    channel.request_history_sync!(
      mode,
      expected_provider_history_synced_at: channel.provider_history_synced_at
    )
  end

  def normalized_qr_payload(response)
    payload = response['qrcode'] || response
    return {} unless payload.is_a?(Hash)

    qr_code = payload.slice('instance', 'pairingCode', 'pairing_code', 'code', 'base64').compact
    qr_code.presence || {}
  end

  def lifecycle_state_for(state, qr_present)
    case normalized_connection_state(state)
    when 'open'
      'connected'
    when 'connecting'
      qr_present ? 'qr_ready' : 'waiting_for_qr'
    when 'reconnecting'
      'reconnecting'
    when 'close'
      qr_present ? 'qr_ready' : 'disconnected'
    when 'refused'
      'failed'
    else
      qr_present ? 'qr_ready' : channel.lifecycle_state
    end
  end

  def normalized_connection_state(state)
    value = state.to_s
    return 'open' if value == 'open'
    return 'connecting' if value == 'connecting'
    return 'reconnecting' if value == 'reconnecting'
    return 'close' if value == 'reauth_required'
    return 'close' if value.in?(%w[close closed disconnected])
    return 'refused' if value == 'refused'

    'unknown'
  end

  def runtime_error_message(payload)
    merged_runtime_message(
      payload['message'],
      payload['status'],
      payload['error'].is_a?(String) ? payload['error'] : nil,
      labeled_runtime_value('status code', payload['statusCode'])
    )
  end

  def runtime_error_for_state(normalized_state, runtime_error)
    return nil if %w[open connecting reconnecting].include?(normalized_state)

    runtime_error.presence || channel.last_error.presence || default_terminal_state_message(normalized_state)
  end

  def message_remote_jid(message)
    contact = message.conversation.contact
    contact_inbox = message.conversation.contact_inbox
    contact_attributes = (contact&.additional_attributes || {}).with_indifferent_access
    whatsapp_profile = whatsapp_channel_profile(contact_attributes, contact_inbox, contact)

    [
      whatsapp_profile&.[](:canonical_jid),
      whatsapp_profile&.[](:raw_jid),
      contact_attributes[:canonical_jid],
      contact_attributes[:raw_jid],
      contact_inbox&.source_id
    ].find(&:present?)
  end

  def whatsapp_channel_profile(contact_attributes, contact_inbox, contact)
    profiles = contact_attributes[:channel_profiles].to_h.with_indifferent_access[:whatsapp_web].to_h.with_indifferent_access
    source_id = contact_inbox&.source_id.to_s.strip
    identifier = contact&.identifier.to_s.strip

    profiles.values.find do |profile|
      attributes = profile.to_h.with_indifferent_access
      [
        attributes[:source_id].to_s.strip,
        attributes[:identifier].to_s.strip,
        attributes[:canonical_jid].to_s.strip,
        attributes[:raw_jid].to_s.strip,
        attributes[:lid_jid].to_s.strip
      ].any?(&:present?) && [
        attributes[:source_id].to_s.strip,
        attributes[:identifier].to_s.strip,
        attributes[:canonical_jid].to_s.strip,
        attributes[:raw_jid].to_s.strip,
        attributes[:lid_jid].to_s.strip
      ].include?(source_id.presence || identifier)
    end || profiles.values.first&.with_indifferent_access
  end

  def default_terminal_state_message(normalized_state)
    case normalized_state
    when 'refused'
      'Evolution connection refused'
    when 'close'
      'Evolution connection closed'
    else
      'Evolution connection unavailable'
    end
  end

  def restart_runtime_session_after_reconnect?
    channel.connection_state.in?(%w[open connecting reconnecting unknown])
  end

  def restart_runtime_session!(force_refresh: false)
    response = request(:post, "/instance/restart/#{channel.instance_name}", body: {})
    sync_from_runtime_response!(response)
    if force_refresh
      refresh_qr! if channel.connection_state != 'open'
    elsif qr_refresh_required_after_reconnect?
      refresh_qr!
    end
    channel
  end

  def authentication_artifacts_present?
    channel.qr_code.present?
  end

  def qr_refresh_required_after_repair?
    return false if channel.connection_state == 'open'
    return false if channel.connection_state == 'reconnecting'
    return true if channel.connection_state.blank?

    channel.connection_state.in?(%w[close refused unknown]) || channel.qr_code.blank?
  end

  def qr_refresh_required_after_reconnect?
    return false if channel.connection_state == 'open'

    channel.qr_code.blank?
  end

  def merged_runtime_message(*messages)
    messages.filter_map do |message|
      value = message.to_s.strip
      value.presence
    end.uniq.presence&.join(' | ')
  end

  def labeled_runtime_value(label, value)
    return if value.blank?

    "#{label}: #{value}"
  end

  def pending_echo_jobs_snapshot
    require 'sidekiq/api'

    queue = Sidekiq::Queue.new('whatsappweb_echo')
    scheduled_jobs = Sidekiq::ScheduledSet.new.select { |job| echo_job?(job) }

    oldest_candidates = []
    oldest_candidates << job_timestamp(queue.first) if queue.first.present?
    oldest_candidates << scheduled_jobs.filter_map { |job| job_timestamp(job) }.min

    {
      backlog: queue.size + scheduled_jobs.size,
      oldest_pending_at: oldest_candidates.compact.min
    }
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] Failed to collect echo diagnostics for channel=#{channel.id}: #{e.class}: #{e.message}")
    { backlog: 0, oldest_pending_at: nil }
  end

  def echo_job?(job)
    klass = job.item['wrapped'] || job.item['class']
    ECHO_JOB_CLASSES.include?(klass)
  end

  def job_timestamp(job)
    timestamp = job.item['enqueued_at'] || job.item['created_at'] || job.item['at']
    return if timestamp.blank?

    Time.zone.at(timestamp.to_f)
  rescue StandardError
    nil
  end

  def create_payload
    {
      instanceName: channel.instance_name,
      qrcode: false,
      number: channel.pairing_number,
      integration: EVOLUTION_INTEGRATION,
      readMessages: false,
      readStatus: false,
      syncFullHistory: true,
      webhook: webhook_payload[:webhook]
    }
  end

  def webhook_payload
    {
      webhook: {
        enabled: true,
        url: channel.webhook_callback_url,
        events: DEFAULT_EVENTS,
        byEvents: false,
        base64: true,
        headers: {
          :jwt_key => channel.webhook_secret,
          'x-onelink-native' => 'true',
          'x-onelink-channel-id' => channel.id.to_s,
          'x-onelink-account-id' => channel.account_id.to_s
        }
      }
    }
  end

  def settings_payload
    {
      rejectCall: false,
      groupsIgnore: false,
      alwaysOnline: false,
      readMessages: false,
      readStatus: false,
      syncFullHistory: true
    }
  end

  def text_payload(message)
    {
      number: recipient_for(message),
      text: formatted_message_content(message),
      quoted: quoted_payload(message)
    }.compact
  end

  def media_payload(message, attachment)
    {
      number: recipient_for(message),
      mediatype: media_type_for(attachment),
      media: attachment_media_url(attachment),
      caption: formatted_message_content(message).presence,
      fileName: attachment_filename(attachment),
      mimetype: attachment.file.blob.content_type,
      quoted: quoted_payload(message)
    }.compact
  end

  def location_payload(message, attachment)
    {
      number: recipient_for(message),
      latitude: attachment.coordinates_lat,
      longitude: attachment.coordinates_long,
      name: formatted_message_content(message).presence || attachment.fallback_title,
      address: attachment.fallback_title,
      quoted: quoted_payload(message)
    }.compact
  end

  def formatted_message_content(message)
    content = message.outgoing_content.to_s
    return content if content.blank?
    return content unless channel.sign_messages?

    sender_name = message.sender&.name.to_s.strip
    return content if sender_name.blank?

    ["*#{sender_name}:*", content].join(channel.formatted_sign_delimiter)
  end

  def recipient_for(message)
    source_id = message.conversation.contact_inbox.source_id.to_s
    return source_id if source_id.include?('@')

    source_id.gsub(/\D/, '')
  end

  def quoted_payload(message)
    reply_to = message.content_attributes&.[]('in_reply_to_external_id') || message.content_attributes&.[](:in_reply_to_external_id)
    return if reply_to.blank?

    {
      key: {
        remoteJid: evolution_remote_jid_for(message),
        id: reply_to
      }
    }
  end

  def evolution_remote_jid_for(message)
    source_id = message.conversation.contact_inbox.source_id.to_s
    return source_id if source_id.include?('@')

    "#{source_id.gsub(/\D/, '')}@s.whatsapp.net"
  end

  def media_type_for(attachment)
    return 'image' if attachment.image?
    return 'video' if attachment.video?
    return 'audio' if attachment.audio?

    'document'
  end

  def attachment_media_url(attachment)
    attachment.download_url.presence || attachment.external_url
  end

  def attachment_filename(attachment)
    return unless attachment.file.attached?

    attachment.file.filename.to_s
  end

  def normalized_remote_jid(remote_jid)
    value = remote_jid.to_s.strip
    return if value.blank?
    return WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(value) if value.include?('@')

    normalized_value = if value.match?(/\A[+\d\-\(\)\s]+\z/)
                         value.gsub(/\D/, '')
                       else
                         value
                       end
    return if normalized_value.blank?

    "#{normalized_value}@s.whatsapp.net"
  end

  def extract_from_me(payload)
    return payload[:fromMe] if payload.key?(:fromMe)
    return payload[:from_me] if payload.key?(:from_me)

    nil
  end

  def request(method, path, body: nil)
    url = "#{base_url}#{path}"
    options = {
      headers: request_headers
    }
    options[:body] = body.to_json if body.present?

    response = HTTParty.public_send(method, url, options)
    parsed = parse_response(response)
    return parsed if response.success?

    raise RequestError.new(parsed_error_message(parsed, response), status: response.code, body: parsed)
  end

  def parse_response(response)
    return {} if response.body.blank?

    response.parsed_response.is_a?(Hash) || response.parsed_response.is_a?(Array) ? response.parsed_response : JSON.parse(response.body)
  rescue JSON::ParserError
    { 'message' => response.body }
  end

  def parsed_error_message(parsed, response)
    parsed['message'].presence || parsed['error'].presence || "Evolution request failed with status #{response.code}"
  end

  def request_headers
    {
      'Content-Type' => 'application/json',
      'apikey' => ENV.fetch('EVOLUTION_API_KEY', '')
    }
  end

  def base_url
    ENV.fetch('EVOLUTION_API_URL', '').to_s.chomp('/')
  end

  def apply_runtime_configuration!
    request(:post, "/webhook/set/#{channel.instance_name}", body: webhook_payload)
    request(:post, "/settings/set/#{channel.instance_name}", body: settings_payload)
  end
end
