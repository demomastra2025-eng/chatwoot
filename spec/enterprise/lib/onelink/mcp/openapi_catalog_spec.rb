# frozen_string_literal: true

require 'rails_helper'

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/openapi_catalog').to_s

RSpec.describe Onelink::Mcp::OpenapiCatalog do
  subject(:catalog) { described_class.new(auth_context: auth_context) }

  let(:account) { instance_double(Account, id: 42) }
  let(:user) { instance_double(User, id: 7) }
  let(:assistant) { instance_double(Captain::Assistant, id: 99) }
  let(:access_policy) { Onelink::Mcp::AccessPolicy.new(account: account, user: user, config: access_policy_config) }
  let(:access_policy_config) { {} }
  let(:auth_context) do
    instance_double(
      Onelink::Mcp::AuthContext,
      account: account,
      user: user,
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
      token_value: 'user-token',
      mcp_access_policy: access_policy
    )
  end

  before do
    allow(Captain::ToolExecutionAuditService).to receive(:record)
  end

  describe '#tools' do
    it 'generates read-only account-scoped tools from the application OpenAPI file' do
      tools = catalog.tools

      expect(tools).to include(hash_including(name: 'api__get_account_details'))
      expect(tools).to all(include(annotations: hash_including(readOnlyHint: true, destructiveHint: false)))
      expect(tools).to all(satisfy { |tool| tool.dig(:_meta, :path).start_with?('/api/v1/accounts/{account_id}') })
    end

    it 'does not expose mutating OpenAPI operations by default' do
      expect(catalog.tools).to all(satisfy { |tool| tool.dig(:_meta, :method) == 'GET' })
    end

    context 'when write API exposure is explicitly enabled' do
      let(:access_policy_config) do
        {
          sources: { openapi_write: true },
          max_risk_level: 'high'
        }
      end

      it 'exposes mutating operations with confirmation metadata' do
        tool = catalog.tools.find { |item| item.dig(:_meta, :method) != 'GET' }

        expect(tool).to be_present
        expect(tool.dig(:_meta, :source)).to eq('openapi_write')
        expect(tool.dig(:_meta, :requires_confirmation)).to be(true)
        expect(tool.dig(:inputSchema, :properties)).to include('_confirm')
      end
    end

    context 'when a legacy policy tries to disable mutation confirmation' do
      let(:access_policy_config) do
        {
          sources: { openapi_write: true },
          max_risk_level: 'custom',
          require_confirmation_for_mutations: false
        }
      end

      it 'still marks OpenAPI mutations as requiring _confirm in the schema' do
        tool = catalog.tools.find { |item| item.dig(:_meta, :method) != 'GET' }

        expect(tool).to be_present
        expect(tool.dig(:_meta, :requires_confirmation)).to be(true)
        expect(tool.dig(:inputSchema, :required)).to include('_confirm')
      end
    end
  end

  describe '#call_tool' do
    it 'dispatches read-only requests through the Rails app with the current account and token' do
      response_body = ['{"resource":{"id":12}}']

      allow(Rails.application).to receive(:call) do |env|
        expect(env['REQUEST_METHOD']).to eq('GET')
        expect(env['PATH_INFO']).to eq('/api/v1/accounts/42/scheduling/resources/12')
        expect(env['HTTP_API_ACCESS_TOKEN']).to eq('user-token')
        [200, { 'Content-Type' => 'application/json' }, response_body]
      end

      result = catalog.call_tool(name: 'api__get_scheduling_resource', arguments: { id: 12 })

      expect(result[:isError]).to be(false)
      expect(result[:structuredContent]).to eq('resource' => { 'id' => 12 })
      expect(Captain::ToolExecutionAuditService).to have_received(:record).with(
        hash_including(
          assistant: assistant,
          scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
          user: user,
          arguments: { id: 12 },
          runtime_context: hash_including(source: 'mcp_openapi')
        )
      )
    end

    it 'preserves an existing Rack Mini Profiler context around internal dispatch' do
      response_body = ['{"resource":{"id":12}}']
      profiler_context = Object.new
      profiler_class = Class.new do
        class << self
          attr_accessor :current
        end
      end
      stub_const('Rack::MiniProfiler', profiler_class)
      Rack::MiniProfiler.current = profiler_context

      allow(Rails.application).to receive(:call) do
        Rack::MiniProfiler.current = nil
        [200, { 'Content-Type' => 'application/json' }, response_body]
      end

      result = catalog.call_tool(name: 'api__get_scheduling_resource', arguments: { id: 12 })

      expect(result[:isError]).to be(false)
      expect(Rack::MiniProfiler.current).to equal(profiler_context)
    end

    context 'when a mutating OpenAPI tool is enabled' do
      let(:access_policy_config) do
        {
          sources: { openapi_write: true },
          max_risk_level: 'high'
        }
      end

      it 'requires explicit confirmation before dispatching the mutation' do
        allow(Rails.application).to receive(:call)

        result = catalog.call_tool(name: 'api__update_account', arguments: {})

        expect(result[:isError]).to be(true)
        expect(result.dig(:content, 0, :text)).to include('_confirm: true')
        expect(Rails.application).not_to have_received(:call)
      end
    end

    context 'when a mutating OpenAPI tool is enabled with legacy confirmation disabled' do
      let(:access_policy_config) do
        {
          sources: { openapi_write: true },
          max_risk_level: 'custom',
          require_confirmation_for_mutations: false
        }
      end

      it 'still blocks the mutation before dispatching into Rails without _confirm' do
        allow(Rails.application).to receive(:call)

        result = catalog.call_tool(name: 'api__update_account', arguments: {})

        expect(result[:isError]).to be(true)
        expect(result.dig(:content, 0, :text)).to include('_confirm: true')
        expect(Rails.application).not_to have_received(:call)
      end
    end
  end
end
