class Reminders::TextModeResolver
  CODE_BLOCK_PATTERN = /```.*?```/m.freeze
  FIELD_REFERENCE_PATTERN = /\(field:\/\/[^)]+\)/.freeze
  INLINE_CODE_PATTERN = /`[^`]*`/.freeze
  LIQUID_OUTPUT_PATTERN = /{{[\s\S]+?}}/.freeze
  LIQUID_TAG_PATTERN = /{%[\s\S]+?%}/.freeze

  class << self
    def call(action_type:, body:, instructions:, text_mode: nil)
      return 'static' unless action_type.to_s == 'send_message'
      return 'agent' if text_mode.to_s == 'agent'

      trimmed_body = body.to_s.strip
      return 'agent' if trimmed_body.blank? && instructions.to_s.strip.present?

      template_syntax?(trimmed_body) ? 'dynamic' : 'static'
    end

    def template_syntax?(content)
      normalized_content = strip_code(content.to_s)
      return false if normalized_content.blank?

      normalized_content.match?(LIQUID_OUTPUT_PATTERN) ||
        normalized_content.match?(LIQUID_TAG_PATTERN) ||
        normalized_content.match?(FIELD_REFERENCE_PATTERN)
    end

    private

    def strip_code(content)
      content.gsub(CODE_BLOCK_PATTERN, ' ').gsub(INLINE_CODE_PATTERN, ' ')
    end
  end
end
