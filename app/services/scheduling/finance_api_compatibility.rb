require 'time'

class Scheduling::FinanceApiCompatibility
  ENV_KEY = 'SCHEDULING_FINANCE_API_COMPATIBILITY_STARTED_AT'.freeze
  WINDOW_SECONDS = 604_800
  INVALID_ANCHOR = Object.new.freeze
  ANCHOR_LOCK = Mutex.new

  class << self
    def active?
      anchor = configured_anchor
      return true if anchor.nil? || anchor.equal?(INVALID_ANCHOR)

      Time.current < anchor + WINDOW_SECONDS
    end

    private

    def configured_anchor
      value = ENV[ENV_KEY]
      return if value.nil?

      ANCHOR_LOCK.synchronize do
        return @cached_anchor if value == @cached_anchor_value

        @cached_anchor_value = value
        @cached_anchor = parse_anchor(value)
        warn_invalid_anchor if @cached_anchor.equal?(INVALID_ANCHOR)
        @cached_anchor
      end
    end

    def parse_anchor(value)
      return INVALID_ANCHOR unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)\z/i)

      Time.iso8601(value).utc
    rescue ArgumentError
      INVALID_ANCHOR
    end

    def warn_invalid_anchor
      invalid_value = @cached_anchor_value
      return if @warned_invalid_values&.key?(invalid_value)

      @warned_invalid_values ||= {}
      @warned_invalid_values[invalid_value] = true
      Rails.logger.warn(
        "[Scheduling::FinanceApiCompatibility] Invalid #{ENV_KEY}; neutral legacy response fields remain enabled. " \
        "Set #{ENV_KEY} to the UTC ISO8601 deployment timestamp (for example 2030-01-15T12:00:00Z)."
      )
    end
  end
end
