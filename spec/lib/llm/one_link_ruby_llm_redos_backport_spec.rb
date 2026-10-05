# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

# Pins config/initializers/ruby_llm_cve_2026_67987_67989.rb (CVE-2026-67987, CVE-2026-67989).
# Ruby 3.2+ memoizes the old regexes, so on this Ruby a timing budget alone cannot tell the
# vulnerable code from the fixed one. The structural examples therefore trace which regexes
# the code runs, and the differential examples compare against the original 1.16.0 code.
RSpec.describe 'ruby_llm ReDoS backports' do # rubocop:disable RSpec/DescribeClass
  let(:openai_chat) { RubyLLM::Providers::OpenAI::Chat }
  let(:mistral_capabilities) { RubyLLM::Providers::Mistral::Capabilities }

  let(:time_budget) { 1 } # seconds; the fixed code needs milliseconds

  # Seconds the block took. The hard caps are for the spec itself: a regex or a loop that
  # runs away raises instead of hanging CI.
  def seconds_taken(&)
    previous = Regexp.timeout
    Regexp.timeout = time_budget * 5
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.timeout(time_budget * 5, &)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  ensure
    Regexp.timeout = previous
  end

  # Regexp objects that were evaluated (Regexp#=== is what `case/when` calls) and the String
  # methods that take a regexp, while the block ran.
  def regexp_activity(subject_string = nil, &)
    activity = []
    trace = TracePoint.new(:c_call) do |point|
      receiver = point.self
      if receiver.is_a?(Regexp) && %i[=== match match? =~].include?(point.method_id)
        activity << receiver.source
      elsif receiver.equal?(subject_string) && %i[scan gsub gsub! sub sub! match match? =~].include?(point.method_id)
        activity << "String##{point.method_id}"
      end
    end
    trace.enable(&)
    activity
  end

  it 'targets exactly the ruby_llm version it was written for' do
    expect(RubyLLM::VERSION).to eq('1.16.0')
  end

  describe 'think tags (CVE-2026-67987)' do
    # The original 1.16.0 implementation, kept here as the reference for behaviour.
    def reference_think_tag_content(text)
      return [text, nil] unless text.include?('<think>')

      thinking = text.scan(%r{<think>(.*?)</think>}m).join
      content = text.gsub(%r{<think>.*?</think>}m, '').strip

      [content.empty? ? nil : content, thinking.empty? ? nil : thinking]
    end

    let(:provider_instance) { Class.new { include RubyLLM::Providers::OpenAI::Chat }.new }

    {
      'plain text' => ['plain', ['plain', nil]],
      'a closed block before the answer' => ['<think>why</think>answer', %w[answer why]],
      'a closed block only' => ['<think>why</think>', [nil, 'why']],
      'several blocks' => ['a<think>1</think>b<think>2</think>c', %w[abc 12]],
      'a multiline block' => ["<think>one\ntwo</think>\nanswer", %W[answer one\ntwo]],
      'an unclosed block' => ['answer<think>never closed', ['answer<think>never closed', nil]],
      'a closed block followed by an unclosed one' => ['<think>a</think>b<think>c', ['b<think>c', 'a']],
      'an empty block' => ['<think></think>answer', ['answer', nil]],
      'a nested opening tag' => ['<think>a<think>b</think>c', ['c', 'a<think>b']],
      'a stray closing tag' => ['x</think>y', ['x</think>y', nil]],
      'cyrillic text' => ['<think>думаю</think>Привет!', ['Привет!', 'думаю']],
      'whitespace around the answer' => ["<think>t</think>\n\n  answer \n", %w[answer t]]
    }.each do |name, (input, expected)|
      it "keeps the behaviour for #{name}" do
        expect(openai_chat.extract_content_and_thinking(input)).to eq(expected)
        expect(provider_instance.send(:extract_content_and_thinking, input)).to eq(expected)
        expect(reference_think_tag_content(input)).to eq(expected)
      end
    end

    it 'still handles non-string content as before' do
      expect(openai_chat.extract_content_and_thinking(nil)).to eq([nil, nil])
      blocks = [{ 'type' => 'thinking', 'thinking' => 'why' }, { 'type' => 'text', 'text' => 'answer' }]
      expect(openai_chat.extract_content_and_thinking(blocks)).to eq(%w[answer why])
    end

    it 'matches the original regex implementation on generated input' do
      random = Random.new(67_987)
      pieces = ['<think>', '</think>', '<think', 'think>', "\n", ' ', 'a', 'Б', '<', '>', '/']

      300.times do
        text = Array.new(random.rand(0..24)) { pieces[random.rand(pieces.size)] }.join

        expect(openai_chat.extract_content_and_thinking(text)).to eq(reference_think_tag_content(text)), text.inspect
      end
    end

    {
      'unclosed tags' => '<think>' * 50_000,
      'unclosed tags with text' => '<think>a' * 50_000,
      'unclosed non-ASCII tags' => '<think>я' * 50_000,
      'many closed blocks' => '<think>a</think>b' * 50_000,
      'closing tags only' => '</think>' * 50_000
    }.each do |name, payload|
      it "stays fast on #{name}" do
        expect(seconds_taken { openai_chat.extract_content_and_thinking(payload) }).to be < time_budget
        expect(seconds_taken { provider_instance.send(:extract_content_and_thinking, payload) }).to be < time_budget
      end
    end

    it 'does not run a regexp over the model reply' do
      payload = '<think>' * 2_000

      activity = regexp_activity(payload) { openai_chat.extract_content_and_thinking(payload) }
      instance_activity = regexp_activity(payload) { provider_instance.send(:extract_content_and_thinking, payload) }

      expect(activity).to be_empty
      expect(instance_activity).to be_empty
    end

    it 'extracts a very long reply in one pass' do
      reply = "#{'<think>step</think>' * 20_000}answer"
      result = nil

      expect(seconds_taken { result = openai_chat.extract_content_and_thinking(reply) }).to be < time_budget
      expect(result).to eq(['answer', 'step' * 20_000])
    end
  end

  describe 'Mistral capabilities (CVE-2026-67989)' do
    # The original 1.16.0 implementation of the branch that used the regexp.
    # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Performance/StringInclude
    def reference_capabilities_for(model_id)
      case model_id
      when /moderation/ then ['moderation']
      when /voxtral.*transcribe/ then ['transcription']
      when /ocr/ then ['vision']
      else
        capabilities = []
        capabilities << 'streaming' if mistral_capabilities.supports_streaming?(model_id)
        capabilities << 'function_calling' if mistral_capabilities.supports_tools?(model_id)
        capabilities << 'structured_output' if mistral_capabilities.supports_json_mode?(model_id)
        capabilities << 'vision' if mistral_capabilities.supports_vision?(model_id)
        capabilities << 'reasoning' if mistral_capabilities.supports_reasoning?(model_id)
        capabilities << 'batch' unless model_id.match?(/voxtral|ocr|embed|moderation/)
        capabilities << 'fine_tuning' if model_id.match?(/mistral-(small|medium|large)|devstral/)
        capabilities << 'distillation' if model_id.match?(/ministral/)
        capabilities << 'predicted_outputs' if model_id.match?(/codestral/)
        capabilities.uniq
      end
    end
    # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Performance/StringInclude

    let(:provider_instance) { Class.new { include RubyLLM::Providers::Mistral::Capabilities }.new }

    {
      'voxtral-mini-transcribe-2507' => ['transcription'],
      'voxtral-small-latest' => ['streaming'],
      'mistral-moderation-latest' => ['moderation'],
      'mistral-ocr-latest' => ['vision'],
      'mistral-embed' => [],
      'mistral-small-latest' => %w[streaming function_calling structured_output reasoning batch fine_tuning],
      'codestral-latest' => %w[streaming function_calling structured_output batch predicted_outputs],
      'ministral-8b-latest' => %w[streaming function_calling structured_output batch distillation]
    }.each do |model_id, expected|
      it "keeps the capabilities of #{model_id}" do
        expect(mistral_capabilities.capabilities_for(model_id)).to eq(expected)
        expect(provider_instance.send(:capabilities_for, model_id)).to eq(expected)
        expect(reference_capabilities_for(model_id)).to eq(expected)
      end
    end

    it 'matches the original implementation for every known Mistral model id' do
      model_ids = RubyLLM.models.all.select { |model| model.provider.to_s == 'mistral' }.map(&:id)

      expect(model_ids).not_to be_empty
      model_ids.each do |model_id|
        expect(mistral_capabilities.capabilities_for(model_id)).to eq(reference_capabilities_for(model_id)), model_id
      end
    end

    it 'matches the original implementation on generated model ids' do
      random = Random.new(67_989)
      pieces = ['voxtral', 'transcribe', 'tts', "\n", '-', 'mini', 'ocr', 'embed', 'moderation', 'mistral-small', '2503', 'x']

      500.times do
        model_id = Array.new(random.rand(0..8)) { pieces[random.rand(pieces.size)] }.join

        expect(mistral_capabilities.capabilities_for(model_id)).to eq(reference_capabilities_for(model_id)), model_id.inspect
      end
    end

    it 'does not look past a line break for the transcribe marker' do
      expect(mistral_capabilities.capabilities_for("voxtral\ntranscribe")).to eq(reference_capabilities_for("voxtral\ntranscribe"))
      expect(mistral_capabilities.capabilities_for("voxtral-a\nvoxtral-transcribe")).to eq(['transcription'])
    end

    {
      'a model id that repeats voxtral' => "#{'voxtral' * 50_000}-nope",
      'a repeated voxtral ending in the marker' => "#{'voxtral' * 50_000}transcribe",
      'a repeated voxtral and a line break' => "#{"voxtral\n" * 50_000}transcribe"
    }.each do |name, model_id|
      it "stays fast on #{name}" do
        expect(seconds_taken { mistral_capabilities.capabilities_for(model_id) }).to be < time_budget
        expect(seconds_taken { provider_instance.send(:capabilities_for, model_id) }).to be < time_budget
      end
    end

    it 'does not run a backtracking pattern over the model id' do
      model_id = "#{'voxtral' * 1_000}-nope"

      sources = regexp_activity(model_id) { mistral_capabilities.capabilities_for(model_id) }
      instance_sources = regexp_activity(model_id) { provider_instance.send(:capabilities_for, model_id) }

      expect(sources.grep(/\.\*/)).to be_empty
      expect(instance_sources.grep(/\.\*/)).to be_empty
    end
  end
end
