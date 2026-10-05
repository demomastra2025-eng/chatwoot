# frozen_string_literal: true

# Backport of the ReDoS fixes for ruby_llm 1.16.0:
#   CVE-2026-67987 (GHSA-5m38-526f-3498), upstream crmne/ruby_llm@5e88411f
#   CVE-2026-67989 (GHSA-57hg-jgw4-wcqw), upstream crmne/ruby_llm@dd3c8481
# RubyLLM 2.0 contains the upstream fixes, but requires a separate persisted-data
# and API migration. Keep the 1.x runtime safe until that migration is complete.
#
# This file is written for exactly one gem version. When ruby_llm is upgraded, delete it
# together with the CVE ignores in .github/workflows/onelink_nightly.yml.
unless RubyLLM::VERSION == '1.16.0'
  raise "config/initializers/ruby_llm_cve_2026_67987_67989.rb patches ruby_llm 1.16.0 but #{RubyLLM::VERSION} is loaded. " \
        'Remove the backport and the CVE-2026-67987/CVE-2026-67989 ignores from .github/workflows/onelink_nightly.yml ' \
        'once the gem contains the upstream fixes, or port the backport to the new version.'
end

# CVE-2026-67987: OpenAI::Chat#extract_think_tag_content ran `<think>(.*?)</think>` through
# String#scan and String#gsub, which is polynomial on a model reply with many unclosed tags
# on Ruby 3.1. Upstream removed the extraction; we keep the behaviour and make it linear.
# Offsets are bytes so that a long non-ASCII reply is not rescanned from the start per tag.
module OneLinkRubyLlmThinkTagBackport
  OPEN_TAG = '<think>'
  CLOSE_TAG = '</think>'

  module_function

  # Same result as the original regexes: every <think>...</think> pair, scanned left to
  # right and non-overlapping, goes to thinking; the rest is the content.
  def split(text)
    thinking = String.new(encoding: text.encoding)
    content = String.new(encoding: text.encoding)
    position = 0

    while (start = text.byteindex(OPEN_TAG, position))
      body_start = start + OPEN_TAG.bytesize
      finish = text.byteindex(CLOSE_TAG, body_start)
      break unless finish

      content << text.byteslice(position, start - position)
      thinking << text.byteslice(body_start, finish - body_start)
      position = finish + CLOSE_TAG.bytesize
    end

    content << text.byteslice(position, text.bytesize - position)
    [thinking, content]
  end

  def extract_think_tag_content(text)
    return [text, nil] unless text.include?(OPEN_TAG)

    thinking, content = split(text)
    content = content.strip

    [content.empty? ? nil : content, thinking.empty? ? nil : thinking]
  end
end

module OneLinkRubyLlmThinkTagExtraction
  def extract_think_tag_content(text)
    OneLinkRubyLlmThinkTagBackport.extract_think_tag_content(text)
  end
end

# CVE-2026-67989: Mistral::Capabilities.capabilities_for matched model ids against
# `/voxtral.*transcribe/`, which is polynomial on an id that repeats "voxtral".
# `.` does not match a newline, so the marker has to follow on the same line.
module OneLinkRubyLlmVoxtralBackport
  VOXTRAL = 'voxtral'

  module_function

  def followed_by?(model_id, marker)
    model_id.to_s.each_line.any? do |line|
      start = line.index(VOXTRAL)
      start && !line.index(marker, start + VOXTRAL.length).nil?
    end
  end
end

module OneLinkRubyLlmMistralCapabilities
  def capabilities_for(model_id) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    case model_id
    when /moderation/ then ['moderation']
    when ->(id) { OneLinkRubyLlmVoxtralBackport.followed_by?(id, 'transcribe') } then ['transcription']
    when /ocr/ then ['vision']
    else
      capabilities = []
      capabilities << 'streaming' if supports_streaming?(model_id)
      capabilities << 'function_calling' if supports_tools?(model_id)
      capabilities << 'structured_output' if supports_json_mode?(model_id)
      capabilities << 'vision' if supports_vision?(model_id)

      capabilities << 'reasoning' if supports_reasoning?(model_id)
      capabilities << 'batch' unless model_id.match?(/voxtral|ocr|embed|moderation/)
      capabilities << 'fine_tuning' if model_id.match?(/mistral-(small|medium|large)|devstral/)
      capabilities << 'distillation' if model_id.include?('ministral')
      capabilities << 'predicted_outputs' if model_id.include?('codestral')

      capabilities.uniq
    end
  end
end

# The gems define these as module_function: a singleton method (called by the provider code
# as RubyLLM::Providers::OpenAI::Chat.extract_content_and_thinking) and a private instance
# copy (used by providers that `include OpenAI::Chat`). Both have to be replaced.
[RubyLLM::Providers::OpenAI::Chat, RubyLLM::Providers::OpenAI::Chat.singleton_class].each do |target|
  target.prepend(OneLinkRubyLlmThinkTagExtraction)
end

[RubyLLM::Providers::Mistral::Capabilities, RubyLLM::Providers::Mistral::Capabilities.singleton_class].each do |target|
  target.prepend(OneLinkRubyLlmMistralCapabilities)
end
