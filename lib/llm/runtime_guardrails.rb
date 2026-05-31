# frozen_string_literal: true

class Llm::RuntimeGuardrails
  Request = Struct.new(:feature, :stage, :text, :account, :preferences, keyword_init: true)

  Match = Struct.new(:guardrail, :rule, :action, :snippet, keyword_init: true) do
    def blocking?
      action == 'block'
    end

    def to_h
      {
        guardrail: guardrail,
        rule: rule,
        action: action,
        snippet: snippet
      }.compact
    end
  end

  REVEAL_PROMPT_PATTERN = /
    (reveal|show|output)\s+(me\s+)?(your\s+)?
    ((full|hidden|complete|internal|secret|original|entire|exact|actual|real)\s+){0,2}
    (system\s+)?(prompt|instructions?)
  /ix

  ROLE_TAG_PATTERN = %r{<\s*/?\s*(system|assistant|developer|tool|function)\s*/?>}i

  PROMPT_INJECTION_PATTERNS = [
    ['ignore_previous_instructions', /ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|directives?)/i],
    ['disregard_previous_instructions', /disregard\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|directives?)/i],
    ['override_instructions', /override\s+(your\s+)?(instructions?|rules?|guidelines?|constraints?|directives?)/i],
    ['developer_mode', /you\s+are\s+now\s+(in\s+)?(developer|admin|debug|maintenance)\s+mode/i],
    ['activate_special_mode', /(enter|activate)\s+(developer|admin|debug|maintenance|jailbreak)\s+mode/i],
    ['system_override', /\bsystem\s+override\b/i],
    ['reveal_prompt', REVEAL_PROMPT_PATTERN],
    ['repeat_instructions', /repeat\s+(the\s+)?(text|instructions?)\s+(above|before)/i],
    ['bypass_safety', /(bypass|disable)\s+(your\s+)?(safety|security|content|ethical)\s+(filters?|measures?|guidelines?|restrictions?)/i],
    ['role_tag_injection', ROLE_TAG_PATTERN],
    ['role_delimiter_injection', /\]\s*\n\s*\[?(system|assistant|user)\]?:/i],
    ['bracketed_role_spoofing', /\[\s*(system\s+message|system|assistant|internal)\s*\]/i],
    ['system_prefix_spoofing', /^\s*system:\s+/i],
    ['control_token_injection', /<\|(?:im_start|im_end|eot_id|start_header_id|end_header_id|endoftext)\|>/i],
    ['deepseek_control_token_injection', /<｜(?:end▁of▁sentence|begin▁of▁sentence)｜>/i]
  ].freeze

  SENSITIVE_INFO_PATTERNS = [
    ['bearer_token', /\bbearer\s+[a-z0-9._\-]{12,}/i],
    ['api_key_assignment', /\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization)\s*[:=]\s*["']?[^\s"'&,;]{8,}/i],
    ['openrouter_or_openai_key', /\bsk-(or-)?[a-z0-9_-]{20,}\b/i],
    ['aws_access_key', /\bAKIA[0-9A-Z]{16}\b/],
    ['private_key_block', /-----BEGIN\s+(RSA\s+|EC\s+|OPENSSH\s+|DSA\s+)?PRIVATE\s+KEY-----/i]
  ].freeze

  GUARDRAILS = {
    prompt_injection: PROMPT_INJECTION_PATTERNS,
    sensitive_info: SENSITIVE_INFO_PATTERNS
  }.freeze

  class << self
    def matches(feature:, stage:, content:, account: nil, preferences: nil)
      text = normalized_text(content)
      return [] if text.blank?

      guardrail_matches(
        Request.new(
          feature: feature,
          stage: stage,
          text: text,
          account: account,
          preferences: preferences
        )
      )
    end

    private

    def guardrail_matches(request)
      GUARDRAILS.flat_map do |guardrail, patterns|
        matches_for_guardrail(guardrail, patterns, request)
      end
    end

    def matches_for_guardrail(guardrail, patterns, request)
      return [] unless guardrail_applies_to_stage?(guardrail, request.stage)

      action = Llm::RuntimePolicy.guardrail_action(
        guardrail: guardrail,
        feature: request.feature,
        account: request.account,
        preferences: request.preferences
      )
      return [] if action == 'disabled'

      patterns.filter_map do |rule, pattern|
        match = request.text.match(pattern)
        next unless match

        Match.new(
          guardrail: guardrail.to_s,
          rule: rule,
          action: action,
          snippet: snippet_for(request.text, match.begin(0), match.end(0))
        )
      end
    end

    def guardrail_applies_to_stage?(guardrail, stage)
      normalized_stage = stage.to_s
      return normalized_stage == 'input' if guardrail.to_s == 'prompt_injection'

      %w[input output].include?(normalized_stage)
    end

    def normalized_text(content)
      case content
      when RubyLLM::Content
        content.text
      when Array
        content.filter_map { |part| text_part(part) }.join("\n")
      else
        content.to_s
      end.to_s.first(Llm::ModerationService::MAX_CONTENT_LENGTH)
    end

    def text_part(part)
      part = part.with_indifferent_access if part.respond_to?(:with_indifferent_access)
      return unless part.is_a?(Hash)
      return unless part[:type].to_s == 'text'

      part[:text]
    end

    def snippet_for(text, start_index, end_index)
      padding = 24
      from = [start_index - padding, 0].max
      to = [end_index + padding, text.length].min
      text[from...to].to_s.squish
    end
  end
end
