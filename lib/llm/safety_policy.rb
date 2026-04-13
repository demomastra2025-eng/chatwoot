# frozen_string_literal: true

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
      blocklist_match = blocklist_match_for(
        feature: feature,
        content: content,
        account: account,
        preferences: preferences
      )
      raise_blocked!(
        feature: feature,
        stage: stage,
        reason: :custom_blocklist,
        rule: blocklist_match
      ) if blocklist_match.present?

      moderation = Llm::ModerationService.check!(
        feature: feature,
        stage: stage,
        content: content,
        account: account,
        preferences: preferences
      )

      CheckResult.new(
        status: moderation.status,
        feature: moderation.feature,
        stage: moderation.stage,
        reason: moderation.reason,
        moderation: moderation
      )
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

    def raise_blocked!(feature:, stage:, reason:, rule: nil)
      Llm::EventBus.publish(
        'safety.blocked',
        feature: feature.to_sym,
        stage: stage.to_sym,
        reason: reason.to_sym,
        rule: rule
      )

      raise UnsafeContentError.new(feature: feature, stage: stage, reason: reason, rule: rule)
    end
  end
end
