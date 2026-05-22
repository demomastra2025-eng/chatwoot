# frozen_string_literal: true

class Llm::EventCode
  MAX_LENGTH = 128
  FORMAT = /\A[a-z0-9][a-z0-9_.-]{0,127}\z/

  class << self
    def normalize(value)
      normalized = value.to_s.strip.first(MAX_LENGTH)
      return if normalized.blank?
      return normalized if normalized.match?(FORMAT)
    end
  end
end
