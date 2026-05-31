# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::FeatureRequest do
  let(:account) { instance_double(Account, id: 42) }
  let(:tool) { instance_double(RubyLLM::Tool, name: 'lookup_contact') }
  let(:schema) do
    Class.new(RubyLLM::Schema) do
      string :message
    end
  end

  def runtime_tool(metadata)
    Class.new do
      define_method(:initialize) { |definition| @definition = definition }
      define_method(:name) { @definition[:id] || 'spec_tool' }
      define_method(:tool_definition) { @definition }
    end.new(metadata)
  end

  it 'normalizes feature aliases and exposes request helpers' do
    request = described_class.new(
      feature: :assistant,
      account: account,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      schema: schema,
      tools: [tool],
      attachments: ['https://example.com/image.png'],
      runtime_preferences: { privacy_profile: 'sensitive' },
      observability: { trace_id: 'trace-1' },
      options: { stream: false }
    )

    expect(request.feature_key).to eq('captain_agent')
    expect(request.account_id).to eq(42)
    expect(request.requires_tools?).to be(true)
    expect(request.requires_schema?).to be(true)
    expect(request.multimodal?).to be(true)
    expect(request.image?).to be(true)
    expect(request.audio?).to be(false)
    expect(request.privacy_profile).to eq('sensitive')
    expect(request.runtime_preferences).to eq(privacy_profile: 'sensitive')
    expect(request.observability).to eq(trace_id: 'trace-1')
    expect(request.options).to eq(stream: false)
  end

  it 'normalizes expanded routing and observability fields' do
    conversation = instance_double(Conversation, id: 7, display_id: 1001)
    request = described_class.new(
      feature: :captain_agent,
      account: account,
      assistant: instance_double(Captain::Assistant),
      conversation: conversation,
      user_id: 9,
      model: 'openai/gpt-5.4-mini',
      models: ['openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4', 'openai/gpt-5.4-mini'],
      messages: [{ role: 'user', content: 'Hello' }],
      schema: schema,
      tool_choice: :auto,
      stream: true,
      reasoning: { effort: 'medium' },
      max_tokens: '512',
      temperature: 0,
      performance_profile: 'fast',
      cost_profile: 'balanced',
      routing_intent: 'tool_reliability',
      cache_policy: 'session',
      plugin_policy: 'structured_output_and_overflow_only',
      server_tools: [{ id: 'datetime' }],
      service_tier: 'priority',
      transform_policy: 'overflow_only',
      budget_policy: 'local_ledger_hard_stop',
      observability_mode: 'metadata_only',
      guardrail_profile: 'crm_tool_mutation_safe',
      variant_policy: %w[exacto thinking],
      observability: { trace_id: 'trace-1' }
    )

    expect(request.conversation).to eq(conversation)
    expect(request.session_id).to eq('42_1001')
    expect(request.session_cache_key).to eq('llm:captain_agent:42:42_1001')
    expect(request.user_id).to eq('9')
    expect(request.models).to eq(['openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4'])
    expect(request.tool_choice).to eq('auto')
    expect(request.stream).to be(true)
    expect(request.reasoning).to eq(effort: 'medium')
    expect(request.reasoning_requested?).to be(true)
    expect(request.schema_required?).to be(true)
    expect(request.max_tokens).to eq(512)
    expect(request.temperature).to eq(0)
    expect(request.performance_profile).to eq('fast')
    expect(request.cost_profile).to eq('balanced')
    expect(request.routing_intent).to eq('tool_reliability')
    expect(request.cache_policy).to eq('session')
    expect(request.plugin_policy).to eq('structured_output_and_overflow_only')
    expect(request.server_tools).to eq([{ id: 'datetime' }])
    expect(request.service_tier).to eq('priority')
    expect(request.transform_policy).to eq('overflow_only')
    expect(request.budget_policy).to eq('local_ledger_hard_stop')
    expect(request.observability_mode).to eq('metadata_only')
    expect(request.guardrail_profile).to eq('crm_tool_mutation_safe')
    expect(request.variant_policy).to eq(%w[exacto thinking])
    expect(request.openrouter_feature_policy.allowed_server_tools).to eq(['openrouter:datetime'])
  end

  it 'allows parallel tool calls only for read-only tool flows' do
    read_only_tool = runtime_tool(id: 'lookup_contact', risk_level: 'low')
    request = described_class.new(
      feature: :captain_agent,
      account: account,
      tools: [read_only_tool],
      parallel_tool_calls: true
    )

    expect(request.read_only_tool_flow?).to be(true)
    expect(request.mutating_tool_flow?).to be(false)
    expect(request.parallel_tool_calls).to be(true)
  end

  it 'disables parallel tool calls for mutating or unknown-idempotency tools' do
    mutating_tool = runtime_tool(id: 'create_deal', risk_level: 'high', idempotent: false)
    unknown_tool = instance_double(RubyLLM::Tool, name: 'unknown_runtime_tool')

    mutating_request = described_class.new(
      feature: :captain_agent,
      account: account,
      tools: [mutating_tool],
      parallel_tool_calls: true
    )
    mutating_default_request = described_class.new(
      feature: :captain_agent,
      account: account,
      tools: [mutating_tool]
    )
    unknown_request = described_class.new(
      feature: :captain_agent,
      account: account,
      tools: [unknown_tool],
      parallel_tool_calls: true
    )

    expect(mutating_request.mutating_tool_flow?).to be(true)
    expect(mutating_request.read_only_tool_flow?).to be(false)
    expect(mutating_request.parallel_tool_calls).to be(false)
    expect(mutating_default_request.parallel_tool_calls).to be(false)
    expect(unknown_request.mutating_tool_flow?).to be(true)
    expect(unknown_request.parallel_tool_calls).to be(false)
  end

  it 'detects native endpoint preference without forcing chat-audio requests onto native endpoints' do
    embedding_request = described_class.new(feature: :embedding, account: account, input: 'knowledge')
    prompted_audio_request = described_class.new(
      feature: :audio_transcription,
      account: account,
      messages: [{ role: 'user', content: 'Transcribe attached audio' }]
    )

    expect(embedding_request.native_endpoint_preferred?).to be(true)
    expect(prompted_audio_request.native_endpoint_preferred?).to be(false)
  end

  it 'treats audio transcription requests as audio and multimodal' do
    request = described_class.new(
      feature: :audio_transcription,
      account: account,
      input: '/tmp/message.ogg'
    )

    expect(request.feature_key).to eq('audio_transcription')
    expect(request.audio?).to be(true)
    expect(request.image?).to be(false)
    expect(request.multimodal?).to be(true)
  end

  it 'maps help center search to the embedding runtime feature' do
    request = described_class.new(feature: :help_center_search, account: account, input: 'knowledge')

    expect(request.feature_key).to eq('embedding')
  end

  it 'inherits privacy profile from account runtime when request preferences are not provided' do
    stored_account = create(:account, captain_runtime: { 'privacy_profile' => 'sensitive' })

    request = described_class.new(feature: :captain_agent, account: stored_account)

    expect(request.privacy_profile).to eq('sensitive')
  end

  it 'rejects blank and unsupported features' do
    expect { described_class.new(feature: nil, account: account) }
      .to raise_error(ArgumentError, /feature is required/)

    expect { described_class.new(feature: :unknown_feature, account: account) }
      .to raise_error(ArgumentError, /Unsupported LLM feature/)
  end

  it 'rejects account-scoped requests without an account' do
    expect { described_class.new(feature: :captain_agent, messages: []) }
      .to raise_error(ArgumentError, /account is required/)
  end

  it 'rejects unsupported privacy profiles' do
    expect do
      described_class.new(feature: :captain_agent, account: account, privacy_profile: 'collect_everything')
    end.to raise_error(ArgumentError, /Unsupported OpenRouter privacy profile/)
  end

  it 'rejects schemas and tools that are not runtime-compatible' do
    expect do
      described_class.new(feature: :captain_agent, account: account, schema: Object.new)
    end.to raise_error(ArgumentError, /schema must be RubyLLM-compatible/)

    expect do
      described_class.new(feature: :captain_agent, account: account, tools: ['lookup_contact'])
    end.to raise_error(ArgumentError, /tools must be RubyLLM-compatible/)
  end
end
