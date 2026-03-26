module WhatsappWeb::ProviderPayloadNormalizer
  extend self

  STATUS_ORDER = {
    'sent' => 1,
    'delivered' => 2,
    'read' => 3
  }.freeze

  def normalize_message_update(record)
    payload = record.to_h.deep_symbolize_keys
    return nil if payload.blank?

    key = payload[:key].to_h.deep_symbolize_keys
    update = payload[:update].to_h.deep_symbolize_keys

    if key[:id].present?
      key[:remoteJid] = canonical_remote_jid(key[:remoteJid], key[:remoteJidAlt], key[:remoteLid])
      return payload.merge(key: key, update: update)
    end

    key_id = payload[:keyId].presence || payload[:id].presence
    return nil if key_id.blank?

    {
      key: {
        id: key_id,
        remoteJid: canonical_remote_jid(payload[:remoteJid], payload[:remoteJidAlt], payload[:remoteLid]),
        fromMe: ActiveModel::Type::Boolean.new.cast(payload[:fromMe]),
        participant: payload[:participant]
      }.compact,
      update: {
        status: payload[:status]
      }.compact,
      messageId: payload[:messageId],
      instanceId: payload[:instanceId]
    }.compact
  end

  def canonical_remote_jid(*candidates)
    values = candidates.filter_map { |candidate| candidate.to_s.presence }
    values.find { |jid| !jid.end_with?('@lid') } || values.first
  end

  def map_message_status(status_code)
    case status_code.to_s.upcase
    when 'PENDING', 'SERVER_ACK'
      :sent
    when 'DELIVERY_ACK'
      :delivered
    when 'READ', 'PLAYED'
      :read
    else
      case status_code.to_i
      when 1
        :sent
      when 2, 3
        :delivered
      when 4
        :read
      else
        nil
      end
    end
  end

  def apply_message_status!(message, status_code)
    mapped_status = map_message_status(status_code)
    return false if mapped_status.blank?
    return false if status_rank(mapped_status) < status_rank(message.status)
    return false if message.status.to_s == mapped_status.to_s

    message.update!(status: mapped_status)
    true
  end

  def provider_lookup_remote_jid(remote_jid)
    value = remote_jid.to_s.strip
    return nil if value.blank? || value.end_with?('@lid')

    value
  end

  def status_rank(status)
    STATUS_ORDER.fetch(status.to_s, 0)
  end
end
