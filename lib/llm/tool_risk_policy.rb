# frozen_string_literal: true

class Llm::ToolRiskPolicy
  READ_ONLY_RISK_LEVELS = %w[low read_only readonly lookup].freeze
  MUTATING_RISK_LEVELS = %w[medium high critical destructive custom].freeze
  TOOL_DEFINITION_METHODS = %i[tool_definition definition metadata to_tool_metadata].freeze
  TOOL_READ_ONLY_KEYS = %i[read_only read_only_hint readonly lookup].freeze
  TOOL_MUTATING_KEYS = %i[mutating mutation destructive destructive_hint side_effect side_effects].freeze
  TOOL_NON_IDEMPOTENT_KEYS = %i[non_idempotent non_retryable].freeze
  BOOLEAN = ActiveModel::Type::Boolean.new

  class << self
    def mutating?(tool)
      metadata = metadata_for(tool)
      return true if metadata.empty?
      return true if mutating_metadata?(metadata)
      return false if read_only_metadata?(metadata)

      true
    end

    def read_only?(tool)
      metadata = metadata_for(tool)
      return false if metadata.empty? || mutating_metadata?(metadata)

      read_only_metadata?(metadata)
    end

    def metadata_for(tool)
      metadata = metadata_candidates(tool).find(&:present?)
      return {} unless metadata.respond_to?(:to_h)

      metadata.to_h.deep_symbolize_keys
    rescue StandardError
      {}
    end

    private

    def metadata_candidates(tool)
      method_metadata_candidates(tool) + to_h_metadata_candidate(tool)
    end

    def method_metadata_candidates(tool)
      TOOL_DEFINITION_METHODS.filter_map do |method_name|
        next unless tool.respond_to?(method_name, true)

        tool.send(method_name)
      rescue StandardError
        nil
      end
    end

    def to_h_metadata_candidate(tool)
      return [] unless tool.respond_to?(:to_h) && !tool.is_a?(Hash)

      [tool.to_h]
    rescue StandardError
      []
    end

    def mutating_metadata?(metadata)
      boolean(metadata, *TOOL_MUTATING_KEYS) == true ||
        boolean(metadata, *TOOL_NON_IDEMPOTENT_KEYS) == true ||
        (boolean(metadata, :idempotent) == false && key?(metadata, :idempotent)) ||
        MUTATING_RISK_LEVELS.include?(metadata[:risk_level].to_s)
    end

    def read_only_metadata?(metadata)
      boolean(metadata, *TOOL_READ_ONLY_KEYS) == true || READ_ONLY_RISK_LEVELS.include?(metadata[:risk_level].to_s)
    end

    def key?(metadata, *keys)
      keys.any? { |key| metadata.key?(key) || metadata.key?(key.to_s) }
    end

    def boolean(metadata, *keys)
      key = keys.find { |candidate| metadata.key?(candidate) || metadata.key?(candidate.to_s) }
      return if key.blank?

      value = metadata.key?(key) ? metadata[key] : metadata[key.to_s]
      BOOLEAN.cast(value)
    end
  end
end
