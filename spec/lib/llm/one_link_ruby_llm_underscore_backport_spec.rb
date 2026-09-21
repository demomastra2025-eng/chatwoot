# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe OneLinkRubyLlmUnderscoreBackport do
  describe OneLinkRubyLlmUnderscoreBackport do
    it 'preserves acronym-aware names' do
      expect(described_class.underscore('MyTool')).to eq('my_tool')
      expect(described_class.underscore('HTTPProxyTool')).to eq('http_proxy_tool')
      expect(described_class.underscore('XMLHttpRequest')).to eq('xml_http_request')
      expect(described_class.underscore('Tool2Name')).to eq('tool2_name')
    end

    it 'handles a long run of capitals within a bounded time' do
      name = 'A' * 100_000

      expect { Timeout.timeout(1) { described_class.underscore(name) } }.not_to raise_error
    end
  end

  it 'applies the safe normalizer to tool names' do
    tool_class = Class.new(RubyLLM::Tool)
    allow(tool_class).to receive(:name).and_return('HTTPProxyTool')

    expect(tool_class.new.name).to eq('http_proxy')
  end

  it 'applies the safe normalizer to agent prompt paths' do
    agent_class = Class.new(RubyLLM::Agent)
    allow(agent_class).to receive(:name).and_return('Captain::HTTPProxyAgent')

    expect(agent_class.send(:prompt_agent_path)).to eq('captain/http_proxy_agent')
  end
end
