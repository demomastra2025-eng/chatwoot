# frozen_string_literal: true

# Customer-facing Captain settings shared by every agent in an account. The
# legacy assistant config is deliberately left intact for rollback.
class Captain::AccountSettings
  KEY = 'captain_agent_settings'
  BOOLEAN_FIELDS = {
    'understanding' => %w[voice_messages images documents web_search web_page_reading],
    'handoff' => %w[auto_completion_enabled auto_reply_on_last_incoming],
    'faq' => %w[generate_from_resolved],
    'safety' => %w[moderation_enabled]
  }.freeze
  MESSAGE_FIELDS = %w[handoff_message resolution_message].freeze
  # The owner's short "how to write" guide for an AI-written handoff or closing message.
  MESSAGE_INSTRUCTION_MAX_LENGTH = 500
  REASON_FIELDS = %w[handoff_reasons completion_reasons].freeze
  ACTION_TO_API = { 'disabled' => 'off', 'flag' => 'flag', 'block' => 'block' }.freeze
  ACTION_FROM_API = ACTION_TO_API.invert.freeze
  RULE_DIRECTION_TO_API = { 'input' => 'inbound', 'output' => 'outbound' }.freeze
  RULE_DIRECTION_FROM_API = RULE_DIRECTION_TO_API.invert.freeze
  RULE_ACTION_TO_API = { 'handoff' => 'handoff', 'block' => 'handoff', 'rewrite' => 'rewrite_once' }.freeze
  RULE_ACTION_FROM_API = { 'handoff' => 'handoff', 'rewrite_once' => 'rewrite' }.freeze
  MESSAGE_MODE_TO_API = { 'static' => 'fixed', 'ai' => 'generated' }.freeze
  MESSAGE_MODE_FROM_API = MESSAGE_MODE_TO_API.invert.freeze

  class Invalid < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super('Invalid Captain account settings')
    end
  end

  def initialize(account)
    @account = account
  end

  def value
    defaults.deep_merge(@account.settings.to_h.fetch(KEY, {}).to_h.deep_stringify_keys)
  end

  def section(name)
    key = name.to_s
    @section_defaults ||= defaults(include_availability: false)
    @section_defaults.fetch(key).deep_merge(@account.settings.to_h.fetch(KEY, {}).to_h.deep_stringify_keys.fetch(key, {}))
  end

  def update!(patch)
    patch = patch.to_unsafe_h if patch.respond_to?(:to_unsafe_h)
    patch = patch.deep_stringify_keys if patch.is_a?(Hash)
    errors = Captain::AccountSettingsValidation.new(defaults).errors(patch)
    raise Invalid, errors if errors.any?

    @account.with_lock do
      @account.reload
      merged = value.deep_merge(patch)
      @account.update!(settings: @account.settings.to_h.merge(KEY => merged.except('availability')))
    end
    value
  end

  def defaults(include_availability: true)
    result = {
      'understanding' => { 'voice_messages' => true, 'images' => true, 'documents' => true,
                           'web_search' => false, 'web_page_reading' => false },
      'handoff' => { 'handoff_reasons' => default_reasons('handoff'), 'completion_reasons' => default_reasons('completion'),
                     'handoff_message' => default_message(true), 'resolution_message' => default_message(false),
                     'auto_completion_enabled' => true, 'auto_reply_on_last_incoming' => false },
      'faq' => { 'generate_from_resolved' => false },
      'conversation' => { 'message_collapse_window_seconds' => 15 },
      'safety' => { 'moderation_enabled' => false, 'prompt_injection_action' => 'block',
                    'sensitive_info_action' => 'block', 'custom_rules' => [] }
    }
    result['availability'] = { 'web_access_configured' => web_access_configured? } if include_availability
    result
  end

  def self.from_assistant(assistant)
    Captain::AccountSettingsSnapshot.new(assistant).value
  end

  def runtime_rules
    section('safety')['custom_rules'].map do |rule|
      rule.merge('direction' => RULE_DIRECTION_FROM_API.fetch(rule['direction']),
                 'action' => RULE_ACTION_FROM_API.fetch(rule['action']))
    end
  end

  private

  def default_reasons(type)
    Captain::OutcomeReasonConfig::BUILTIN_IDS.fetch(type).map do |id|
      { 'id' => id, 'label' => I18n.t("captain.outcome_reasons.#{id}", locale: @account.locale, default: id.humanize),
        'enabled' => true, 'builtin' => true }
    end
  end

  def default_message(enabled)
    { 'enabled' => enabled, 'mode' => 'fixed', 'text' => '', 'instruction' => '' }
  end

  def web_access_configured?
    Captain::Tools::FirecrawlService.configured?
  end
end
