# Maps a failed WhatsApp Web send to the short Russian reason shown to the operator in the message's external_error.
# The technical detail (provider status and body) is logged by the caller and never shown in the UI.
module WhatsappWeb::DeliveryFailureReason
  DISCONNECTED = 'WhatsApp отключён — переподключите номер в настройках канала'.freeze
  GROUP_NOT_FOUND = 'Группа не найдена в WhatsApp (возможно, номер удалили из группы)'.freeze
  UNROUTABLE_RECIPIENT = 'Не удалось определить номер получателя'.freeze
  GENERIC = 'Не удалось отправить сообщение в WhatsApp'.freeze

  # Failures stored before the Russian reasons existed carried this English fragment.
  LEGACY_UNROUTABLE_FRAGMENT = 'provisional @lid identity'.freeze
  GROUP_NOT_FOUND_PATTERN = /group not found/i
  DISCONNECTED_PATTERN = Regexp.union(
    /connection (closed|terminated|lost|failure)/i,
    /logged[ _-]?out|logout/i,
    /not connected|socket (is )?closed|stream errored/i,
    /instance .{0,80}(does not exist|not found|not connected|closed)/i
  )
  # Bare HTTP reason phrases tell the operator nothing, so they are replaced by the generic reason.
  BARE_HTTP_REASONS = [
    'bad request', 'not found', 'gone', 'conflict', 'forbidden', 'unauthorized', 'unprocessable entity', 'unprocessable content',
    'internal server error', 'internal error'
  ].freeze

  module_function

  # The gateway often hides the real cause behind a bare "Bad Request" (for example a group lookup fails only because the
  # session is closed), so a channel that is known to be disconnected explains any ambiguous failure.
  def reason_for(error, channel: nil)
    return UNROUTABLE_RECIPIENT if error.is_a?(WhatsappWeb::Providers::EvolutionService::UnroutableRecipientError)

    details = error.respond_to?(:error_details) ? error.error_details : error.message.to_s
    return DISCONNECTED if details.match?(DISCONNECTED_PATTERN)

    ambiguous_reason(details, error.message, channel) || error.message.to_s.presence || GENERIC
  end

  def unroutable_recipient?(external_error)
    text = external_error.to_s
    text.include?(UNROUTABLE_RECIPIENT) || text.include?(LEGACY_UNROUTABLE_FRAGMENT)
  end

  def ambiguous_reason(details, message, channel)
    group_missing = details.match?(GROUP_NOT_FOUND_PATTERN)
    bare = bare_http_reason?(message)
    return DISCONNECTED if (group_missing || bare) && channel_disconnected?(channel)
    return GROUP_NOT_FOUND if group_missing

    GENERIC if bare
  end

  def channel_disconnected?(channel)
    channel.present? && channel.connection_state.in?(%w[close refused])
  end

  def bare_http_reason?(message)
    value = message.to_s.strip.downcase
    value.blank? || BARE_HTTP_REASONS.include?(value)
  end
end
