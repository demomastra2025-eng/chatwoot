# frozen_string_literal: true

module Captain::KnowledgeSettings
  DEFAULT_CHUNK_SIZE = 20_000
  MIN_CHUNK_SIZE = 2_000
  MAX_CHUNK_SIZE = 50_000
  CHUNK_SIZE_OPTIONS = [8_000, 12_000, 16_000, 20_000, 24_000, 32_000, 40_000, 50_000].freeze
  CHARS_PER_TOKEN_ESTIMATE = 4.0
  CHUNK_SIZE_ROUNDING_STEP = 1_000
  VECTOR_DIMENSIONS = 1536

  class << self
    def runtime_defaults
      {
        'knowledge_chunk_size' => DEFAULT_CHUNK_SIZE
      }
    end

    def chunk_size_for(account)
      normalize_chunk_size(account&.captain_runtime.to_h['knowledge_chunk_size'])
    end

    def normalize_chunk_size(value)
      size = integer_value(value)
      size = DEFAULT_CHUNK_SIZE if size.blank?
      size.clamp(MIN_CHUNK_SIZE, MAX_CHUNK_SIZE)
    end

    def estimated_tokens_for_chunk_size(chunk_size)
      (normalize_chunk_size(chunk_size) / CHARS_PER_TOKEN_ESTIMATE).ceil
    end

    def estimated_tokens_for_account(account)
      estimated_tokens_for_chunk_size(chunk_size_for(account))
    end

    def chunk_size_options_for_context_lengths(context_lengths, include_values: [])
      context_options = Array(context_lengths).filter_map do |context_length|
        chunk_size_for_context_length(context_length)
      end

      options = context_options + Array(include_values).map { |value| normalize_chunk_size(value) }
      options = CHUNK_SIZE_OPTIONS if options.blank?
      options.uniq.sort
    end

    def chunk_size_for_context_length(context_length)
      tokens = integer_value(context_length)
      return if tokens.blank? || tokens <= 0

      raw_size = (tokens * CHARS_PER_TOKEN_ESTIMATE).floor
      rounded_size = (raw_size / CHUNK_SIZE_ROUNDING_STEP) * CHUNK_SIZE_ROUNDING_STEP
      normalized_size = rounded_size.clamp(MIN_CHUNK_SIZE, MAX_CHUNK_SIZE)
      normalized_size.positive? ? normalized_size : MIN_CHUNK_SIZE
    end

    def metadata_for(account)
      chunk_size = chunk_size_for(account)

      {
        chunk_size: chunk_size,
        default_chunk_size: DEFAULT_CHUNK_SIZE,
        min_chunk_size: MIN_CHUNK_SIZE,
        max_chunk_size: MAX_CHUNK_SIZE,
        estimated_tokens: estimated_tokens_for_chunk_size(chunk_size),
        chars_per_token_estimate: CHARS_PER_TOKEN_ESTIMATE,
        vector_dimensions: VECTOR_DIMENSIONS
      }
    end

    private

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
