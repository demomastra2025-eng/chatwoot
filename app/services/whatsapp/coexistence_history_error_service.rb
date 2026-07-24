class Whatsapp::CoexistenceHistoryErrorService
  DECLINED_ERROR_CODE = 2_593_109

  def initialize(channel:)
    @channel = channel
  end

  def record(history)
    errors = Array(history[:errors]).map(&:with_indifferent_access)
    declined = errors.any? { |error| error[:code].to_i == DECLINED_ERROR_CODE }
    update_sync_config(
      'state' => declined ? 'history_declined' : 'history_failed',
      'history_errors' => errors.map { |error| sanitized_error(error) },
      'history_error_at' => Time.current.iso8601
    )
  end

  private

  def sanitized_error(error)
    {
      code: error[:code],
      title: safe_text(error[:title]),
      message: safe_text(error[:message])
    }.compact
  end

  def safe_text(value)
    Meta::CredentialDataSanitizer.sanitize(
      value.to_s.first(200),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@channel)
    ).presence
  end

  def update_sync_config(attributes)
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next if Whatsapp::CoexistenceSyncService.terminal_state?(sync)

      config['coexistence_sync'] = sync.merge(attributes)
      @channel.persist_provider_config_state!(config)
    end
  end
end
