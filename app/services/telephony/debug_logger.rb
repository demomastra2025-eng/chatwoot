require 'fileutils'

class Telephony::DebugLogger
  DEFAULT_LOG_PATH = Rails.root.join('log/telephony_bridge_debug.log').to_s

  class << self
    def log(event:, payload:, log_path: default_log_path)
      return unless enabled?

      serialized_event = payload.merge(event: event, timestamp: Time.current.iso8601).to_json
      append(serialized_event, log_path: log_path)
    end

    def default_log_path
      ENV.fetch('TELEPHONY_BRIDGE_DEBUG_LOG_PATH', DEFAULT_LOG_PATH).to_s
    end

    def enabled?
      Rails.env.development? || ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEPHONY_DEBUG_LOGGING', false))
    end

    private

    def append(serialized_event, log_path:)
      return if log_path.blank?

      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, 'a') { |file| file.puts(serialized_event) }
    rescue SystemCallError => e
      Rails.logger.warn(
        {
          event: 'telephony_bridge_debug_log_write_failed',
          path: log_path,
          error: e.message
        }.to_json
      )
    end
  end
end
