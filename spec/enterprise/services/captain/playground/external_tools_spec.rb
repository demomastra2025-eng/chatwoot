require 'rails_helper'
require 'open3'
require 'ruby_llm/mcp'
require 'tmpdir'

RSpec.describe 'Playground external tool isolation' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:channel_sms, account: account).inbox }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  let(:legacy_policy) { Outbound::PlaygroundDeliveryPolicy.issue(mode: 'live', run_id: SecureRandom.uuid, delivery_enabled: true) }
  let(:legacy_conversation) do
    create(:conversation, account: account, inbox: inbox, additional_attributes: { 'captain_playground' => legacy_policy })
  end
  let(:custom_tool) do
    create(:captain_custom_tool, :with_post, account: account, slug: 'custom_playground_external_send',
                                           endpoint_url: 'https://example.com/outbound', request_template: '{}')
  end
  let(:mcp_server) { create(:captain_mcp_server, account: account) }
  let(:mcp_definition) do
    { id: 'mcp__playground__send_message', description: 'Send an external message', provider: 'mcp',
      mcp_server_id: mcp_server.id, mcp_tool_name: 'send_message', risk_level: 'low',
      input_schema: { 'type' => 'object', 'properties' => {} } }
  end
  let(:script_definition) do
    { id: 'skill__playground__send_message', description: 'Send an external message', provider: 'skill_script', risk_level: 'low' }
  end
  let(:script) do
    { id: 'send_message', skill_id: 'playground', runtime: 'ruby', network: true,
      source_path: @script_directory, script_path: File.join(@script_directory, 'send.rb'),
      parameters_schema: { 'type' => 'object', 'properties' => {} } }
  end
  let(:external_tools) do
    [{ id: custom_tool.slug, custom: true }, mcp_definition, script_definition].map do |definition|
      Captain::ToolCatalog.build_tool(definition, assistant: assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT)
    end
  end

  before do
    allow(assistant).to receive(:description).and_return('Use tool://mcp__playground__send_message')
    allow(Captain::SkillCatalog).to receive(:script_for_tool_id).with(script_definition[:id], account: account).and_return(script)
  end

  around do |example|
    Dir.mktmpdir('playground-external-tools-') do |directory|
      @script_directory = directory
      File.write(File.join(directory, 'send.rb'), 'puts "External script executed"')
      with_modified_env(
        Captain::SkillScriptRunner::ENABLED_ENV => 'true', Captain::SkillScriptRunner::NETWORK_ENABLED_ENV => 'true'
      ) do
        example.run
      end
    end
  end

  after { Current.reset }

  def block_transports!
    expect(Resolv).not_to receive(:getaddresses)
    expect(Net::HTTP).not_to receive(:new)
    expect(RubyLLM::MCP).not_to receive(:client)
    expect(Open3).not_to receive(:capture3)
  end

  def expect_blocked(result)
    expect(Captain::ToolResult.error?(result)).to be(true)
    payload = result.is_a?(String) ? JSON.parse(result.delete_prefix('ERROR:').strip).deep_symbolize_keys : result
    expect(payload[:data]).to include(code: 'unsupported_external_tool_in_playground',
                                     reason: 'unsupported_external_tool_in_playground', blocked: true, delivered: false)
    expect(payload[:retryable]).to be(false)
  end

  def wrappers_for(runner, playground: nil)
    payload = { state: runner.send(:build_state) }
    payload[:playground_session] = playground if playground
    context = Captain::Runtime::RunContext.new(payload)
    agent = Captain::Runtime::Agent.new(name: 'external_tools', tools: external_tools)
    Captain::Runtime::ChatFactory.send(:record_bound_agent_tools, agent, context)
    [Captain::Runtime::ChatFactory.send(:build_agent_tools, agent, context), context]
  end

  def execute_transports(state: {})
    context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state }))
    executor = Captain::Tools::HttpRequestExecutor.new(assistant: assistant, custom_tool: custom_tool, state: state)
    [
      executor.call,
      executor.execute_with_details[:tool_result],
      Captain::Mcp::ExecutionService.new(mcp_server: mcp_server, tool_name: 'send_message', params: {}).call,
      Captain::SkillScriptRunner.new(script: script, assistant: assistant, tool_context: context, params: {}).call
    ]
  end

  [false, true].each do |real_access|
    context "with real-data permissions #{real_access ? 'enabled' : 'disabled'}" do

      it 'blocks dynamically built HTTP, MCP and script tools in the actual chat wrapper before their executors' do
        session.with_lock do |live|
          live.set_permissions!(read: real_access, write: real_access)
          block_transports!
          expect(Captain::Tools::HttpRequestExecutor).not_to receive(:new)
          expect(Captain::Mcp::ExecutionService).not_to receive(:new)
          expect(Captain::SkillScriptRunner).not_to receive(:new)
          runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, source: 'playground', playground_session: live)
          wrappers, = wrappers_for(runner, playground: live)

          expect(external_tools.first.class.superclass).to eq(Captain::Tools::HttpTool)
          expect(Current.playground_run_policy).to be_nil
          wrappers.each { |wrapper| expect_blocked(wrapper.call({})) }
        end
      end

      it 'blocks a later ordinary runner for a captured legacy conversation without a Playground session' do
        session.with_lock do
          block_transports!
          runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: legacy_conversation)
          allow(runner).to receive(:generate_response_in_runtime_cache) do
            expect(Current.playground_run_policy).to eq(legacy_policy)
            wrappers, context = wrappers_for(runner)
            expect(context.context).not_to have_key(:playground_session)
            expect(context.context[:state]).not_to have_key(:playground)
            runner.send(:with_mcp_discovery_policy) do
              expect(Captain::Mcp::ToolCatalog.available_tools_for(assistant, 'agent')).to eq([])
            end
            wrappers.each { |wrapper| expect_blocked(wrapper.call({})) }
            { 'response' => 'External tools blocked' }
          end

          expect(runner.generate_response['response']).to eq('External tools blocked')
          expect(Current.playground_run_policy).to be_nil
        end
      end

      it 'blocks the shared HTTP/MCP/subprocess transport entrypoints with the captured signed policy' do
        session.with_lock do |live|
          live.set_permissions!(read: real_access, write: real_access)
          block_transports!
          Outbound::PlaygroundDeliveryPolicy.with(live.run_policy) do
            execute_transports.each { |result| expect_blocked(result) }
            expect { Captain::Mcp::ClientBuilder.with_client(mcp_server) { 'Unreachable' } }
              .to raise_error(Captain::Playground::ExternalToolPolicy::Blocked, /unsupported_external_tool_in_playground/)
          end
        end
      end

      it 'does not discover MCP tools for a workspace source even before Current has been installed' do
        session.with_lock do |live|
          live.set_permissions!(read: real_access, write: real_access)
          block_transports!
          expect(Captain::Mcp::ToolCatalog::DiscoveryService).not_to receive(:new)
          runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, source: 'playground', playground_session: live)
          expect(Current.playground_run_policy).to be_nil
          runner.send(:with_mcp_discovery_policy) do
            expect(Captain::Mcp::ToolCatalog.available_tools_for(assistant, 'agent')).to eq([])
          end
        end
      end
    end
  end

  it 'blocks invalid inherited policy at every transport without dropping false or empty policy' do
    block_transports!
    [false, {}, { 'token' => 'invalid' }].each do |inherited|
      Outbound::PlaygroundDeliveryPolicy.with(inherited) do
        execute_transports.each { |result| expect_blocked(result) }
        expect { Captain::Mcp::ClientBuilder.with_client(mcp_server) { 'Unreachable' } }
          .to raise_error(Captain::Playground::ExternalToolPolicy::Blocked)
        expect(Current.playground_run_policy).to eq(inherited)
      end
    end
  end

  it 'blocks direct tool execution from a persisted test caller context even without Current or a session' do
    session.with_lock do
      block_transports!
      runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: legacy_conversation)
      context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: runner.send(:build_state) }))

      expect(Current.playground_run_policy).to be_nil
      expect_blocked(external_tools.first.perform(context))
      expect_blocked(external_tools.second.perform(context))
      expect_blocked(external_tools.third.perform(context))
    end
  end

  it 'does not poison the ordinary MCP discovery failure cache when a test run is blocked' do
    block_transports!
    discovery = Captain::Mcp::ToolCatalog::DiscoveryService.new(mcp_server)
    expect(Rails.cache).not_to receive(:write)
    Outbound::PlaygroundDeliveryPolicy.with(false) do
      expect(Captain::Mcp::ToolCatalog.available_tools_for(assistant, 'agent')).to eq([])
      expect { discovery.tools(refresh: true) }.to raise_error(Captain::Playground::ExternalToolPolicy::Blocked)
    end
  end

  it 'keeps the ordinary custom HTTP transport and MCP client lifecycle working without test policy' do
    allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
    request = stub_request(:post, 'https://example.com/outbound').to_return(status: 200, body: '{"sent":true}')
    http_result = Captain::Tools::HttpRequestExecutor.new(assistant: assistant, custom_tool: custom_tool).call
    expect(Captain::ToolResult.error?(http_result)).to be(false)
    expect(request).to have_been_requested.once

    remote_tool = double('remote tool', execute: 'Ordinary reply')
    client = instance_double(RubyLLM::MCP::Client, start: nil, stop: nil)
    allow(client).to receive(:tool).with('send_message', refresh: true).and_return(remote_tool)
    allow(RubyLLM::MCP).to receive(:client).and_return(client)
    expect(Captain::Mcp::ExecutionService.new(mcp_server: mcp_server, tool_name: 'send_message', params: {}).call).to eq('Ordinary reply')
    expect(client).to have_received(:start).once
    expect(client).to have_received(:stop).once
  end
end
