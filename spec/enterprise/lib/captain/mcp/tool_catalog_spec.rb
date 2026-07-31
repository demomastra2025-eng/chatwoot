require 'rails_helper'

RSpec.describe Captain::Mcp::ToolCatalog do
  describe '.available_tools_for' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let!(:own_server) { create(:captain_mcp_server, account: account, slug: 'own_server') }

    before do
      create(:captain_mcp_server, account: create(:account), slug: 'other_server')
      allow(described_class::DiscoveryService).to receive(:new) do |server|
        instance_double(described_class::DiscoveryService, tools: [tool_payload_for(server)])
      end
    end

    it 'returns MCP tools only from the assistant account' do
      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include('mcp__own_server__lookup')
      expect(tool_ids).not_to include('mcp__other_server__lookup')
    end

    it 'keeps tools from healthy servers when another server fails discovery' do
      healthy_server = create(:captain_mcp_server, account: account, slug: 'healthy_server')
      allow(described_class::DiscoveryService).to receive(:new) do |server|
        discovery = instance_double(described_class::DiscoveryService)
        if server == own_server
          allow(discovery).to receive(:tools).and_raise(Timeout::Error, 'unavailable')
        else
          allow(discovery).to receive(:tools).and_return([tool_payload_for(server)])
        end
        discovery
      end

      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include("mcp__#{healthy_server.slug}__lookup")
      expect(tool_ids).not_to include("mcp__#{own_server.slug}__lookup")
    end

    def tool_payload_for(server)
      {
        id: "mcp__#{server.slug}__lookup",
        title: "#{server.slug} lookup",
        description: 'Lookup data',
        mcp_tool_name: 'lookup',
        input_schema: { 'type' => 'object', 'properties' => {} }
      }
    end
  end

  describe Captain::Mcp::ToolCatalog::DiscoveryService do
    let(:account) { create(:account) }
    let(:mcp_server) { create(:captain_mcp_server, account: account, slug: 'discovery_server') }
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }
    let(:annotations) do
      instance_double(
        RubyLLM::MCP::Annotation,
        title: 'Lookup order',
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true
      )
    end
    let(:remote_tool) do
      instance_double(
        RubyLLM::MCP::Tool,
        name: 'lookup_order',
        description: 'Looks up an order',
        annotations: annotations,
        params_schema: { 'type' => 'object', 'properties' => {} }
      )
    end
    let(:client) { instance_double(RubyLLM::MCP::Client, tools: [remote_tool]) }
    let(:service) { described_class.new(mcp_server) }

    before do
      allow(Rails).to receive(:cache).and_return(cache)
      allow(Captain::Mcp::ClientBuilder).to receive(:with_client).and_yield(client)
    end

    it 'discovers through the qualified client builder and caches the result' do
      first_result = service.tools
      second_result = service.tools

      expect(first_result).to eq(second_result)
      expect(first_result.first).to include(
        id: 'mcp__discovery_server__lookup_order',
        title: 'Lookup order',
        risk_level: 'low',
        idempotent: true
      )
      expect(Captain::Mcp::ClientBuilder).to have_received(:with_client).once.with(
        mcp_server,
        timeout_seconds: Captain::Mcp::ToolCatalog::DISCOVERY_TIMEOUT_SECONDS
      )
    end

    it 'retries one transient timeout before succeeding' do
      attempts = 0
      allow(service).to receive(:sleep)
      allow(Captain::Mcp::ClientBuilder).to receive(:with_client) do |*, **, &block|
        attempts += 1
        raise Timeout::Error, 'temporary timeout' if attempts == 1

        block.call(client)
      end

      expect(service.tools(refresh: true)).to be_present
      expect(attempts).to eq(2)
      expect(service).to have_received(:sleep).with(Captain::Mcp::ToolCatalog::DISCOVERY_RETRY_DELAY_SECONDS)
    end

    it 'does not retry programming errors and applies a short failure backoff' do
      allow(Captain::Mcp::ClientBuilder).to receive(:with_client).and_raise(NameError, 'broken namespace')

      expect { service.tools }.to raise_error(NameError, 'broken namespace')
      expect(service.tools).to eq([])
      expect(Captain::Mcp::ClientBuilder).to have_received(:with_client).once
    end
  end
end
