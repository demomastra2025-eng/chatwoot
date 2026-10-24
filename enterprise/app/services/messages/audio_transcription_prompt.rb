# frozen_string_literal: true

# What a voice message transcription is told about the speech, for both ways the platform transcribes it.
#
# A dedicated transcription model (gpt-4o-transcribe, gpt-4o-mini-transcribe, whisper) reads `prompt` as the text spoken
# right before the audio, not as an instruction. A short sample written in Kazakh and Russian Cyrillic therefore keeps
# Kazakh speech in Kazakh spelling instead of a close language such as Kyrgyz. A chat model that hears the audio follows
# instructions, so it is told the same in words. The workspace prompt (captain_runtime.audio_transcription_prompt)
# replaces both defaults. The language is never forced: many voice messages are in Russian.
#
# The sample says nothing a customer would say (no greeting, request or price): if a model repeats it on silence or a very
# short clip, Captain must not read it as a customer message. See #without_echoed_context.
#
#   prompt = Messages::AudioTranscriptionPrompt.new(account.captain_audio_transcription_prompt)
#   prompt.for_transcription_endpoint # => the workspace prompt, or CONTEXT_SAMPLE
#   prompt.for_chat                   # => CHAT_INSTRUCTION and the workspace prompt, or CHAT_LANGUAGE_HINT
class Messages::AudioTranscriptionPrompt
  # A Kazakh sentence with the letters Kyrgyz spelling does not have (ә ғ қ ұ і) and then a Russian one
  SAMPLE_SENTENCES = [
    'Біздің ұлттық мәдениетіміз, ғылымымыз бен өнеріміз әлемге танымал.',
    'Мы говорим на казахском и русском языках.'
  ].freeze
  CONTEXT_SAMPLE = SAMPLE_SENTENCES.join(' ').freeze
  CHAT_INSTRUCTION = 'Transcribe the attached audio accurately. Return only the transcript text, without markdown or commentary.'
  CHAT_LANGUAGE_HINT = [
    'The speaker is in Kazakhstan and usually speaks Kazakh or Russian, sometimes both in one message.',
    'Write Kazakh speech in Kazakh Cyrillic spelling (ә, ғ, қ, ң, ө, ұ, ү, һ, і), not in Kyrgyz spelling,',
    'and Russian speech in Russian. Keep every phrase in the language it was spoken; do not translate.'
  ].join(' ').freeze

  def initialize(workspace_prompt)
    @workspace_prompt = workspace_prompt.to_s.strip.presence
  end

  # The `prompt` of a transcription endpoint: context that precedes the audio
  def for_transcription_endpoint
    @workspace_prompt || CONTEXT_SAMPLE
  end

  # The text sent together with the audio to a chat model
  def for_chat
    [CHAT_INSTRUCTION, @workspace_prompt || CHAT_LANGUAGE_HINT].join("\n")
  end

  # A transcription model may return its context together with the transcript, mostly for silence or a very short clip,
  # and may repeat only a part of it. The built-in sample is not something the customer said, so every verbatim copy of
  # one of its sentences is removed. Only the built-in sample is touched, never the workspace prompt.
  def without_echoed_context(text)
    return text.to_s if @workspace_prompt.present?

    SAMPLE_SENTENCES.reduce(text.to_s) { |transcript, sentence| transcript.gsub(/#{Regexp.escape(sentence)}\s*/, '') }.strip
  end
end
