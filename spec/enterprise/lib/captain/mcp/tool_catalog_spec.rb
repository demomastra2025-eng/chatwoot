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
      allow(Rails.logger).to receive(:warn)
      allow(described_class::DiscoveryService).to receive(:new) do |server|
        discovery = instance_double(described_class::DiscoveryService)
        if server == own_server
          allow(discovery).to receive(:tools).and_raise(Timeout::Error, 'unavailable token=secret-value')
        else
          allow(discovery).to receive(:tools).and_return([tool_payload_for(server)])
        end
        discovery
      end

      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include("mcp__#{healthy_server.slug}__lookup")
      expect(tool_ids).not_to include("mcp__#{own_server.slug}__lookup")
      expect(Rails.logger).to have_received(:warn).with(include("mcp_server=#{own_server.id}: Timeout::Error"))
      expect(Rails.logger).not_to have_received(:warn).with(include('secret-value'))
    end

    it 'reuses a failed discovery result inside one runtime when the Rails cache is disabled' do
      discovery = instance_double(described_class::DiscoveryService)
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::NullStore.new)
      allow(described_class::DiscoveryService).to receive(:new).and_return(discovery)
      allow(discovery).to receive(:tools).and_raise(Timeout::Error, 'unavailable')

      results = described_class.with_runtime_cache do
        Array.new(3) { described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT) }
      end

      expect(results).to eq([[], [], []])
      expect(described_class::DiscoveryService).to have_received(:new).once
      expect(discovery).to have_received(:tools).once
    end

    it 'isolates cached results by account and scope' do
      other_account = create(:account)
      other_assistant = create(:captain_assistant, account: other_account)
      create(:captain_mcp_server, account: other_account, slug: 'second_account_server')

      described_class.with_runtime_cache do
        described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT)
        described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT)
        described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
        described_class.available_tools_for(other_assistant, Captain::ToolAccess::SCOPE_AGENT)
      end

      expect(described_class::DiscoveryService).to have_received(:new).exactly(3).times
    end

    it 'restores the outer runtime cache after a nested runtime raises' do
      original_cache = Thread.current[described_class::RUNTIME_CACHE_KEY]
      outer_cache = nil

      described_class.with_runtime_cache do
        outer_cache = Thread.current[described_class::RUNTIME_CACHE_KEY]

        expect do
          described_class.with_runtime_cache { raise 'runtime failure' }
        end.to raise_error(RuntimeError, 'runtime failure')

        expect(Thread.current[described_class::RUNTIME_CACHE_KEY]).to equal(outer_cache)
      end

      expect(Thread.current[described_class::RUNTIME_CACHE_KEY]).to equal(original_cache)
    end

    it 'skips discovery inside a scoped fallback and restores thread state after errors' do
      original_value = Thread.current[described_class::DISCOVERY_DISABLED_KEY]
      expect(described_class::DiscoveryService).not_to receive(:new)

      expect do
        described_class.without_discovery do
          expect(described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT)).to eq([])
          raise 'fallback failure'
        end
      end.to raise_error(RuntimeError, 'fallback failure')

      expect(Thread.current[described_class::DISCOVERY_DISABLED_KEY]).to equal(original_value)
    end

    it 'isolates runtime caches between worker threads' do
      threads = Array.new(2) do
        Thread.new do
          described_class.with_runtime_cache { Thread.current[described_class::RUNTIME_CACHE_KEY] }
        end
      end
      thread_caches = threads.map(&:value)

      expect(thread_caches.first).not_to equal(thread_caches.last)
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

    it 'invalidates a failure cache when the server changes within the same second' do
      updated_at = Time.zone.parse('2026-08-23 10:00:00.100000')
      attempts = 0
      allow(mcp_server).to receive(:updated_at) { updated_at }
      allow(Captain::Mcp::ClientBuilder).to receive(:with_client) do |*, **, &block|
        attempts += 1
        raise NameError, 'broken namespace' if attempts == 1

        block.call(client)
      end

      expect { service.tools }.to raise_error(NameError, 'broken namespace')
      updated_at += 0.1

      expect(service.tools).to be_present
      expect(attempts).to eq(2)
    end
  end
end
