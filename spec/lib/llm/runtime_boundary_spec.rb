# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Runtime do
  let(:direct_runtime_patterns) do
    {
      'Llm::ChatClient' => /\bLlm::ChatClient\s*\.\s*(?:build|ask)\b/,
      'Llm::ApiClient' => /\bLlm::ApiClient\s*\.\s*(?:embed|moderate|transcribe)\b/,
      'RubyLLM runtime adapter' => /\bRubyLLM\s*\.\s*(?:chat|embed|moderate|transcribe)\b/
    }
  end

  let(:allowed_direct_runtime_paths) do
    {
      'lib/llm/api_client.rb' => 'internal RubyLLM compatibility adapter',
      'lib/llm/chat_client.rb' => 'internal RubyLLM chat adapter',
      'lib/llm/chat_request_runner.rb' => 'internal runtime runner bridge',
      'lib/llm/open_router_runtime.rb' => 'OpenRouter runtime adapter'
    }
  end

  it 'keeps normal product code behind Llm::Runtime' do
    violations = scanned_ruby_files.each_with_object([]) do |path, result|
      relative_path = path.relative_path_from(Rails.root).to_s
      next if allowed_direct_runtime_paths.key?(relative_path)

      path.each_line.with_index(1) do |line, line_number|
        direct_runtime_patterns.each do |label, pattern|
          next unless line.match?(pattern)

          result << "#{relative_path}:#{line_number} uses #{label} directly"
        end
      end
    end

    expect(violations).to be_empty, <<~MESSAGE
      Product LLM calls must go through Llm::Runtime. If a direct adapter call is intentional,
      keep it inside an internal adapter and add the file to the spec allowlist.
      Existing allowlisted product fallbacks must not grow without an explicit migration/deferred reason.

      Violations:
      #{violations.join("\n")}
    MESSAGE
  end

  it 'keeps every direct adapter allowlist entry documented' do
    undocumented = allowed_direct_runtime_paths.select { |_path, reason| reason.blank? }

    expect(undocumented).to be_empty
  end

  def scanned_ruby_files
    %w[app enterprise lib].flat_map do |directory|
      Dir.glob(Rails.root.join(directory, '**/*.rb')).map { |path| Pathname.new(path) }
    end
  end
end
