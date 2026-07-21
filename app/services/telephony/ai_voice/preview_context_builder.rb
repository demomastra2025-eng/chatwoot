class Telephony::AiVoice::PreviewContextBuilder
  PREVIEW_MAX_DURATION_SEC = 120

  pattr_initialize [:assistant!]

  def perform
    {
      call_ref: "preview:#{assistant.id}:#{SecureRandom.uuid}",
      account_id: assistant.account_id,
      provider: 'browser_preview',
      direction: 'preview',
      ai: voice_settings.merge(
        'system_prompt' => system_prompt,
        'max_duration_sec' => [voice_settings['max_duration_sec'].to_i, PREVIEW_MAX_DURATION_SEC].reject(&:zero?).min || PREVIEW_MAX_DURATION_SEC
      ),
      captain: {
        assistant_id: assistant.id,
        name: assistant.name,
        preview: true
      },
      recording: { enabled: false, source: 'preview' },
      tools: []
    }
  end

  private

  def voice_settings
    @voice_settings ||= Telephony::AiVoice::VoiceSettingsDefaults.normalize(
      assistant.config.to_h.deep_stringify_keys.fetch('voice_settings', {})
    ).except('recording_enabled')
  end

  def system_prompt
    [
      compiled_prompt,
      voice_settings['system_prompt'].presence,
      voice_character_prompt,
      Telephony::AiVoice::ContextBuilder::DEFAULT_SYSTEM_PROMPT,
      Telephony::AiVoice::ContextBuilder::VOICE_RESPONSE_CONTRACT
    ].compact_blank.join("\n\n")
  end

  def compiled_prompt
    preview = Captain::Assistant::PromptPreviewService.new(assistant: assistant).preview
    preview.dig(:assistant, :compiled_prompt) || preview.dig('assistant', 'compiled_prompt')
  end

  def voice_character_prompt
    value = voice_settings['voice_character_prompt'].to_s.strip
    return if value.blank?

    "#{Telephony::AiVoice::ContextBuilder::VOICE_CHARACTER_PROMPT_LABEL}:\n#{value}"
  end
end
