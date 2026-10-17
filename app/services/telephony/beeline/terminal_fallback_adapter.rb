# frozen_string_literal: true

module Telephony
  module Beeline
    class TerminalFallbackAdapter
      TERMINAL_STATUSES = %w[completed missed no_answer busy failed cancelled].freeze

      def initialize(payload = nil, **kwargs)
        raw = payload || kwargs[:payload] || {}
        @payload = raw.respond_to?(:deep_stringify_keys) ? raw.deep_stringify_keys.deep_dup : {}
      end

      def call
        return nil if @payload.blank?

        status = @payload['status'].to_s
        return nil unless TERMINAL_STATUSES.include?(status)

        direction = @payload['direction'].to_s.presence || 'inbound'
        if direction == 'inbound' && %w[missed no_answer].include?(status)
          @payload['event'] = 'missed'
          @payload['status'] = 'missed'
        end

        metadata = @payload['metadata'].is_a?(Hash) ? @payload['metadata'].deep_stringify_keys : {}
        @payload['metadata'] = metadata.merge(
          'beeline_webhook_mode' => 'terminal_fallback',
          'beeline_webhook_unmatched' => true,
          'terminal_fallback' => true,
          'fallback_reason' => 'no_active_webphone_session',
          'route_action' => 'operator',
          'routing_mode' => 'operator'
        )
        @payload
      end

      alias payload call
    end
  end
end
