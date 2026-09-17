# frozen_string_literal: true

class Telephony::Sipuni::TerminalFallbackAdapter
  def initialize(payload)
    @payload = payload.deep_stringify_keys.deep_dup
  end

  def payload
    return unless unmatched_missed_event?

    metadata = @payload['metadata'].is_a?(Hash) ? @payload['metadata'] : {}
    @payload['metadata'] = metadata.merge(
      'sipuni_webhook_mode' => 'terminal_fallback',
      'sipuni_webhook_unmatched' => true
    )
    @payload['event'] = 'missed'
    @payload['status'] = 'missed'
    @payload
  end

  private

  def unmatched_missed_event?
    return false unless @payload['direction'] == 'inbound'
    return false unless @payload.dig('metadata', 'sipuni_event').to_s == '2'

    @payload['status'] == 'no_answer' || @payload['end_reason'] == 'CHANUNAVAIL'
  end
end
