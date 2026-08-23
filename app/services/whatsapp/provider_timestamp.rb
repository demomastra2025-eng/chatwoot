class Whatsapp::ProviderTimestamp
  MINIMUM_TIMESTAMP = Time.utc(2009, 1, 1).to_i
  MILLISECOND_THRESHOLD = 1_000_000_000_000

  class << self
    def normalize(value, now: Time.current)
      raw_value = value.to_s
      return unless raw_value.match?(/\A\d+\z/)

      timestamp = raw_value.to_i
      timestamp /= 1000 if timestamp >= MILLISECOND_THRESHOLD
      return unless timestamp.between?(MINIMUM_TIMESTAMP, now.to_i + 1.day.to_i)

      timestamp
    end

    def time(value, now: Time.current)
      timestamp = normalize(value, now: now)
      Time.zone.at(timestamp) if timestamp.present?
    rescue ArgumentError, RangeError
      nil
    end

    def invalid_supplied?(value, now: Time.current)
      !value.nil? && value != '' && normalize(value, now: now).nil?
    end
  end
end
