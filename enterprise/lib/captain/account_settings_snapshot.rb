# frozen_string_literal: true

class Captain::AccountSettingsSnapshot
  def initialize(assistant)
    @assistant = assistant
  end

  def value
    {
      'understanding' => understanding,
      'handoff' => handoff,
      'faq' => { 'generate_from_resolved' => boolean(config.fetch('feature_faq', false)) },
      'conversation' => { 'message_collapse_window_seconds' => config.fetch('message_collapse_window_seconds', 0).to_i },
      'safety' => safety
    }
  end

  private

  attr_reader :assistant

  def config
    @config ||= assistant.config.to_h.deep_stringify_keys
  end

  def boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def understanding
    audio_setting = config['use_audio_transcriptions']
    {
      'voice_messages' => audio_setting.nil? || boolean(audio_setting),
      'images' => boolean(config.fetch('feature_image_understanding', true)),
      'documents' => boolean(config.fetch('feature_document_reading', true)),
      'web_search' => legacy_web_enabled?('web_search'),
      'web_page_reading' => legacy_web_enabled?('web_scrape_url')
    }
  end

  def legacy_web_enabled?(tool_id)
    access = Captain::ToolAccess.raw_scope(config, 'agent')
    return boolean(config.fetch('feature_web', true)) unless access.is_a?(Hash)

    enabled = boolean(access.fetch('enabled', true))
    selected = Array(access.fetch('tool_ids', Captain::ToolAccess::DEFAULT_AGENT_TOOL_IDS))
    enabled && selected.include?(tool_id)
  end

  def handoff
    reasons = Captain::OutcomeReasonConfig.new(assistant, source: :assistant).normalized_settings
    {
      'handoff_reasons' => api_reasons(reasons['handoff_reasons']),
      'completion_reasons' => api_reasons(reasons['completion_reasons']),
      'handoff_message' => api_message('handoff_message'),
      'resolution_message' => api_message('resolution_message'),
      'auto_completion_enabled' => boolean(config.fetch('auto_completion_enabled', true)),
      'auto_reply_on_last_incoming' => boolean(config.fetch('auto_reply_on_last_incoming', false))
    }
  end

  def api_reasons(reasons)
    Array(reasons).map do |reason|
      { 'id' => reason['id'], 'label' => reason['label'], 'enabled' => reason['active'], 'builtin' => !reason['removable'] }
    end
  end

  # In AI mode the old per-agent text was the owner's wishes for the message ("Пожелания к сообщению"), never a sentence for the
  # customer. The new settings send `text` to a customer as the fallback when the notice model fails, so the wishes move to
  # `instruction` (the "how to write" guide) and the fallback text stays empty. Only a fixed message keeps its text.
  def api_message(key)
    mode = Captain::AccountSettings::MESSAGE_MODE_TO_API.fetch(config["#{key}_mode"], 'fixed')
    text = config[key].to_s
    generated = mode == 'generated'
    { 'enabled' => boolean(config.fetch("#{key}_enabled", true)),
      'mode' => mode,
      'text' => generated ? '' : text,
      'instruction' => generated ? text.squish.first(Captain::AccountSettings::MESSAGE_INSTRUCTION_MAX_LENGTH) : '' }
  end

  def safety
    # Legacy data is no longer validated on save, so only a hash is read.
    old = config['safety_settings'].is_a?(Hash) ? config['safety_settings'] : {}
    moderation = old['moderation_enabled']
    moderation = assistant.account.captain_runtime_preferences['assistant_moderation'] if moderation.nil?
    {
      'moderation_enabled' => boolean(moderation),
      'prompt_injection_action' => Captain::AccountSettings::ACTION_TO_API.fetch(old['prompt_injection_action'], 'block'),
      'sensitive_info_action' => Captain::AccountSettings::ACTION_TO_API.fetch(old['sensitive_info_action'], 'block'),
      'custom_rules' => Array(old['custom_rules']).grep(Hash).map { |rule| api_rule(rule) }
    }
  end

  def api_rule(raw_rule)
    rule = raw_rule.to_h.deep_stringify_keys
    rule.merge('direction' => Captain::AccountSettings::RULE_DIRECTION_TO_API.fetch(rule['direction'], 'inbound'),
               'action' => Captain::AccountSettings::RULE_ACTION_TO_API.fetch(rule['action'], 'handoff'))
  end
end
