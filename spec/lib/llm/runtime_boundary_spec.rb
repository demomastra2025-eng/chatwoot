# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Runtime do
  let(:direct_runtime_patterns) do
    {
      'Llm::ChatClient' => /\bLlm::ChatClient\s*\.\s*(?:build|ask)\b/,
      'RubyLLM.chat' => /\bRubyLLM\s*\.\s*chat\b/
    }
  end

  let(:allowed_direct_runtime_paths) do
    %w[
      lib/llm/chat_client.rb
      lib/llm/chat_request_runner.rb
      lib/llm/open_router_runtime.rb
    ]
  end

  it 'keeps normal product code behind Llm::Runtime' do
    violations = scanned_ruby_files.each_with_object([]) do |path, result|
      relative_path = path.relative_path_from(Rails.root).to_s
      next if allowed_direct_runtime_paths.include?(relative_path)

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

      Violations:
      #{violations.join("\n")}
    MESSAGE
  end

  def scanned_ruby_files
    %w[app enterprise lib].flat_map do |directory|
      Dir.glob(Rails.root.join(directory, '**/*.rb')).map { |path| Pathname.new(path) }
    end
  end
end
