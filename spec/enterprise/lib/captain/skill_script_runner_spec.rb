require 'rails_helper'
require 'ostruct'

RSpec.describe Captain::SkillScriptRunner do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool_context) { OpenStruct.new(state: { source: 'spec', conversation: { id: 42 } }) }

  it 'does not execute scripts unless the runtime gate is enabled' do
    Dir.mktmpdir do |dir|
      script_path = File.join(dir, 'script.rb')
      File.write(script_path, 'puts "executed"')

      runner = described_class.new(
        script: script_payload(dir, script_path),
        assistant: assistant,
        tool_context: tool_context,
        params: { text: 'hello' }
      )

      with_modified_env(described_class::ENABLED_ENV => nil) do
        result = runner.call

        expect(result).to include(success: false)
        expect(result[:error]).to include('Skill script execution is disabled')
      end
    end
  end

  it 'executes allowlisted ruby scripts with sanitized JSON stdin when enabled' do
    Dir.mktmpdir do |dir|
      script_path = File.join(dir, 'script.rb')
      File.write(
        script_path,
        <<~RUBY
          require 'json'
          payload = JSON.parse(STDIN.read)
          puts "text=\#{payload.dig('params', 'text')};account=\#{payload.dig('context', 'account_id')}"
        RUBY
      )

      runner = described_class.new(
        script: script_payload(dir, script_path),
        assistant: assistant,
        tool_context: tool_context,
        params: { text: 'hello' }
      )

      with_modified_env(described_class::ENABLED_ENV => 'true') do
        result = runner.call

        expect(result).to include(success: true)
        expect(result[:message]).to include("text=hello;account=#{account.id}")
      end
    end
  end

  it 'blocks scripts that request network access unless the network gate is enabled' do
    Dir.mktmpdir do |dir|
      script_path = File.join(dir, 'script.rb')
      File.write(script_path, 'puts "network"')

      runner = described_class.new(
        script: script_payload(dir, script_path).merge(network: true),
        assistant: assistant,
        tool_context: tool_context,
        params: {}
      )

      with_modified_env(described_class::ENABLED_ENV => 'true', described_class::NETWORK_ENABLED_ENV => nil) do
        result = runner.call

        expect(result).to include(success: false)
        expect(result[:error]).to include('network access is disabled')
      end
    end
  end

  def script_payload(dir, script_path)
    {
      id: 'script',
      skill_id: 'support-flow',
      runtime: 'ruby',
      source_path: dir,
      script_path: script_path,
      timeout_seconds: 5
    }
  end
end
