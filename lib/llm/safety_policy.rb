# frozen_string_literal: true

require 'digest'

class Llm::SafetyPolicy
  CheckResult = Struct.new(:status, :feature, :stage, :reason, :rule, :moderation, keyword_init: true)

  class UnsafeContentError < StandardError
    attr_reader :feature, :stage, :reason, :rule

    def initialize(feature:, stage:, reason:, rule: nil)
      @feature = feature
      @stage = stage
      @reason = reason
      @rule = rule

      super("Safety policy blocked #{feature} #{stage}: #{reason}")
    end
  end

  class UnavailableError < StandardError
    attr_reader :feature, :stage, :reason

    def initialize(feature:, stage:, reason:)
      @feature = feature
      @stage = stage
      @reason = reason

      super("Safety policy unavailable for #{feature} #{stage}: #{reason}")
    end
  end

  class << self
    def check!(feature:, stage:, content:, account: nil, preferences: nil)
      request = safety_request(
        feature: feature,
        stage: stage,
        content: content,
        account: account,
        preferences: preferences
      )

      enforce_runtime_guardrails!(**request)
      enforce_custom_blocklist!(**request)
      check_result_for(moderation_check!(**request))
    rescue Llm::ModerationService::FlaggedContentError
      raise_blocked!(
        feature: feature,
        stage: stage,
        reason: :moderation_flagged,
        rule: :provider_moderation
      )
    rescue Llm::ModerationService::UnavailableError => e
      raise UnavailableError.new(feature: e.feature, stage: e.stage, reason: e.reason)
    end

    private

    def safety_request(feature:, stage:, content:, account:, preferences:)
      {
        feature: feature,
        stage: stage,
        content: content,
        account: account,
        preferences: preferences
      }
    end

    def moderation_check!(feature:, stage:, content:, account:, preferences:)
      Llm::ModerationService.check!(
        feature: feature,
        stage: stage,
        content: content,
        account: account,
        preferences: preferences
      )
    end

    def check_result_for(moderation)
      CheckResult.new(
        status: moderation.status,
        feature: moderation.feature,
        stage: moderation.stage,
        reason: moderation.reason,
        moderation: moderation
      )
    end

    def enforce_runtime_guardrails!(feature:, stage:, content:, account:, preferences:)
      matches = Llm::RuntimeGuardrails.matches(
        feature: feature,
        stage: stage,
        content: content,
        account: account,
        preferences: preferences
      )
      return if matches.blank?

      matches.each { |match| publish_guardrail_flagged_event(feature: feature, stage: stage, match: match) }
      blocking_match = matches.find(&:blocking?)
      return unless blocking_match

      raise_blocked!(
        feature: feature,
        stage: stage,
        reason: blocking_match.guardrail,
        rule: blocking_match.rule
      )
    end

    def enforce_custom_blocklist!(feature:, stage:, content:, account:, preferences:)
      blocklist_match = blocklist_match_for(
        feature: feature,
        content: content,
        account: account,
        preferences: preferences
      )
      return if blocklist_match.blank?

      raise_blocked!(
        feature: feature,
        stage: stage,
        reason: :custom_blocklist,
        rule: blocklist_match
      )
    end

    def blocklist_match_for(feature:, content:, account:, preferences:)
      blocklist = Llm::RuntimePolicy.safety_blocklist(
        feature: feature,
        account: account,
        preferences: preferences
      )
      return if blocklist.blank?

      text = Llm::ModerationService.normalized_text(content).downcase
      return if text.blank?

      blocklist.find { |phrase| text.include?(phrase) }
    end

    def publish_guardrail_flagged_event(feature:, stage:, match:)
      Llm::EventBus.publish(
        'safety.flagged',
        feature: feature.to_sym,
        stage: stage.to_sym,
        reason: match.guardrail.to_sym,
        rule: match.rule,
        action: match.action,
        snippet_hash: snippet_hash(match.snippet)
      )
    end

    def snippet_hash(snippet)
      return if snippet.blank?

      Digest::SHA256.hexdigest(snippet.to_s)
    end

    def raise_blocked!(feature:, stage:, reason:, rule: nil)
      normalized_reason = reason.to_sym
      Llm::EventBus.publish(
        'safety.blocked',
        feature: feature.to_sym,
        stage: stage.to_sym,
        reason: normalized_reason,
        rule: rule
      )

      raise UnsafeContentError.new(feature: feature, stage: stage, reason: normalized_reason, rule: rule)
    end
  end
end
