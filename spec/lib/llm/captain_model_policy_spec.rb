# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CaptainModelPolicy do
  let(:luna) { 'openai/gpt-5.6-luna' }
  let(:other) { 'openai/gpt-5.4' }

  def configure_allowlist(value)
    allow(InstallationConfig).to receive(:find_by).and_call_original
    config = instance_double(InstallationConfig, value: value)
    allow(InstallationConfig).to receive(:find_by).with(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').and_return(config)
  end

  it 'allows only Luna by default for Captain and leaves Copilot unaffected' do
    expect(described_class.allowed_models).to eq([luna])
    expect { described_class.ensure_allowed!(feature: :assistant, model: luna) }.not_to raise_error
    expect { described_class.ensure_allowed!(feature: :captain_agent, model: other) }
      .to raise_error(described_class::DisallowedModelError)
    expect { described_class.ensure_allowed!(feature: :copilot, model: other) }.not_to raise_error
  end

  it 'fails closed on invalid, empty or non-array explicit installation allowlists' do
    ['{invalid json', 'null', []].each do |value|
      configure_allowlist(value)
      expect { described_class.ensure_allowed!(feature: :captain, model: luna) }
        .to raise_error(described_class::DisallowedModelError)
    end
  end

  it 'normalizes explicitly allowed model ids but rejects non-allowlisted fallback models' do
    configure_allowlist(["  #{luna}  ", luna])
    expect(described_class.allowed_models).to eq([luna])
    expect { described_class.ensure_allowed!(feature: :captain_agent, model: luna, fallback_models: [other]) }
      .to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'rejects a missing primary even when a fallback is on the allowlist' do
    expect { described_class.ensure_allowed!(feature: :captain_agent, model: nil, fallback_models: [luna]) }
      .to raise_error(described_class::DisallowedModelError, /missing/)
  end

  it 'filters implicit OpenRouter fallbacks without leaking non-allowlisted models' do
    route = Llm::OpenRouterRoutingProfile.for(feature: :assistant, model: luna)
    expect(route.models).to eq([luna])
  end

  it 'honors the account fallback opt-out even when the installation permits two models' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: false } })
    route = Llm::OpenRouterRoutingProfile.for(feature: :captain_agent, model: luna, account: account)
    expect(route.models).to eq([luna])
    expect(route.model_fallbacks_allowed?).to be(false)
    expect(route.provider_preferences).to include(allow_fallbacks: true)
  end

  it 'rejects explicit feature request overrides and raw compiler fallbacks before egress' do
    expect do
      Llm::FeatureRequest.new(feature: :captain_agent, account: instance_double(Account, id: 42), model: luna, models: [luna, other])
    end.to raise_error(described_class::DisallowedModelError)

    request = Struct.new(:feature_key, :models, :options, keyword_init: true).new(
      feature_key: 'captain_agent', models: [luna, other], options: {}
    )
    expect do
      Llm::OpenRouterRequestCompiler.call(request: request, model: luna)
    end.to raise_error(described_class::DisallowedModelError)
  end

  it 'rejects explicit fallbacks when disabled even if all models are allowlisted' do
    configure_allowlist([luna, other])
    request = Struct.new(:feature_key, :models, :runtime_preferences, :options, keyword_init: true).new(
      feature_key: 'captain_agent', models: [luna, other],
      runtime_preferences: { openrouter_allow_model_fallbacks: false }, options: {}
    )
    expect do
      Llm::OpenRouterRequestCompiler.call(request: request, model: luna)
    end.to raise_error(ArgumentError, /Cross-model fallbacks are disabled/)
  end

  it 'does not permit caller-supplied wire model and models to replace a validated route' do
    request = Struct.new(:feature_key, :models, :options, keyword_init: true).new(
      feature_key: 'captain_agent', models: [luna], options: {}
    )
    compiled = Llm::OpenRouterRequestCompiler.call(
      request: request, model: luna,
      base_params: { 'model' => other, 'models' => [other] }
    )
    expect(compiled.model).to eq(luna)
    expect(compiled.params[:models]).to eq([luna])
    expect(compiled.params).not_to include(:model, 'model', 'models')
  end

  it 'rejects prebuilt and mutated Captain chats even when an allowed option was supplied' do
    chat = instance_double(RubyLLM::Chat, model: instance_double(RubyLLM::Model::Info, id: other))
    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna)
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
    Llm::OpenRouterRequestPolicy.tag!(chat, feature: :captain_agent, model: luna)
    expect do
      Llm::ChatClient.ask(chat, 'customer message', model: luna)
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'rejects direct ChatClient wire overrides before build and rechecks params before ask' do
    chat = instance_double(RubyLLM::Chat, model: instance_double(RubyLLM::Model::Info, id: luna),
                                          params: { 'models' => [luna, other] })

    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna, params: { models: [other] })
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna, params: { 'model' => other })
    end.to raise_error(described_class::DisallowedModelError, /symbol key/)
    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna, params: { model: nil, models: [luna] })
    end.to raise_error(described_class::DisallowedModelError, /empty/)
    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna, params: { models: [] })
    end.to raise_error(described_class::DisallowedModelError, /nonempty array/)

    Llm::OpenRouterRequestPolicy.tag!(chat, feature: :captain_agent, model: luna)
    expect do
      Llm::ChatClient.ask(chat, 'customer message', model: luna)
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'keeps the Captain guard for cloned chats that lost their routing tag' do
    chat = instance_double(RubyLLM::Chat, model: instance_double(RubyLLM::Model::Info, id: other), params: {})

    expect { Llm::ChatClient.ask(chat, 'customer message', feature: :captain_agent, model: luna) }
      .to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'rejects colliding wire keys before RubyLLM serializes a forbidden last model' do
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    chat.with_params(**{ 'model' => other, model: luna })
    provider = chat.instance_variable_get(:@provider)
    sdk_payload = RubyLLM::Utils.deep_merge(
      provider.send(:render_payload, [], tools: {}, temperature: nil, model: chat.model, stream: false), chat.params
    )
    expect(sdk_payload.to_json.scan(/"model":/).size).to eq(2)
    expect(JSON.parse(sdk_payload.to_json).fetch('model')).to eq(other)

    expect(provider).not_to receive(:sync_response)
    expect { Llm::ChatClient.ask(chat, 'hello', feature: :captain_agent) }
      .to raise_error(described_class::DisallowedModelError, /Duplicate Captain wire model keys/)

    chat.with_params(**{ models: [luna], 'models' => [other] })
    expect { Llm::ChatClient.ask(chat, 'hello', feature: :captain_agent) }
      .to raise_error(described_class::DisallowedModelError, /Duplicate Captain wire models keys/)
  end

  it 'checks the SDK boundary after callbacks and on every recursive completion' do
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    provider = chat.instance_variable_get(:@provider)
    Llm::CaptainModelPolicy.guard_chat!(feature: :captain_agent, chat: chat)
    tool_call = RubyLLM::ToolCall.new(id: 'call_1', name: 'lookup', arguments: {})
    tool_response = RubyLLM::Message.new(role: :assistant, content: '', tool_calls: { 'call_1' => tool_call })
    chat.after_message { |message| chat.with_params(model: other) if message.role.to_s == 'tool' }
    expect(provider).to receive(:sync_response).once.and_return(tool_response)

    expect { chat.complete }.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'blocks an in-place streaming callback mutation at the provider boundary' do
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    chat.with_params(model: luna)
    provider = chat.instance_variable_get(:@provider)
    chat.before_message { chat.params[:model] = other }
    Llm::CaptainModelPolicy.guard_chat!(feature: :captain_agent, chat: chat)
    expect(provider).not_to receive(:stream_response)
    chunks = []

    expect { chat.complete { |chunk| chunks << chunk } }.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
    expect(chunks).to be_empty
  end

  it 'rejects an installation-allowed second model after an account opt-out streaming callback changes routing metadata' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: false } },
                                       feature_enabled?: false)
    compiled = Llm::OpenRouterRequestCompiler.call(feature: :captain_agent, model: luna, account: account)
    expect(compiled.params[:models]).to eq([luna])
    expect(compiled.params[:provider]).to include(allow_fallbacks: true)

    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = Llm::ChatClient.build(
      chat: context.chat(model: luna, provider: 'openrouter', assume_model_exists: true),
      feature: :captain_agent, model: luna, account: account, params: compiled.params, routing_metadata: compiled.metadata
    )
    chat.before_message do
      chat.params[:models] = [luna, other]
      Llm::OpenRouterRequestPolicy.tag!(chat, routing_metadata: { openrouter_allow_model_fallbacks: true })
    end
    expect(chat.params[:models]).to eq([luna])
    expect(chat.instance_variable_get(:@onelink_openrouter_routing_metadata)[:openrouter_allow_model_fallbacks]).to be(false)
    expect(chat.instance_variable_get(:@provider)).not_to receive(:stream_response)

    expect { chat.complete { |_chunk| nil } }.to raise_error(described_class::DisallowedModelError, /fallback/)
    expect(chat.params[:models]).to eq([luna, other])
  end

  it 'keeps a compiled model opt-out when the account allows fallbacks but a callback changes the metadata' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: true } },
                                       feature_enabled?: false)
    request = Struct.new(:feature_key, :runtime_preferences, :options, keyword_init: true).new(
      feature_key: 'captain_agent', runtime_preferences: { openrouter_allow_model_fallbacks: false }, options: {}
    )
    compiled = Llm::OpenRouterRequestCompiler.call(request: request, model: luna, account: account)
    expect(compiled.metadata[:openrouter_allow_model_fallbacks]).to be(false)

    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = Llm::ChatClient.build(
      chat: context.chat(model: luna, provider: 'openrouter', assume_model_exists: true),
      feature: :captain_agent, model: luna, account: account, params: compiled.params, routing_metadata: compiled.metadata
    )
    chat.before_message do
      chat.params[:models] = [luna, other]
      Llm::OpenRouterRequestPolicy.tag!(chat, routing_metadata: { openrouter_allow_model_fallbacks: true })
    end
    expect(chat.instance_variable_get(:@provider)).not_to receive(:stream_response)

    expect { chat.complete { |_chunk| nil } }.to raise_error(described_class::DisallowedModelError, /fallback/)
  end

  it 'narrows a chat built before account binding when the later account disables model fallbacks' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: false } },
                                       feature_enabled?: false)
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = Llm::ChatClient.build(chat: context.chat(model: luna, provider: 'openrouter', assume_model_exists: true),
                                 feature: :captain_agent, model: luna, params: { models: [luna] })
    provider = chat.instance_variable_get(:@provider)
    response = RubyLLM::Message.new(role: :assistant, content: 'ok')
    chat.after_message { chat.params[:models] = [luna, other] }
    expect(provider).to receive(:sync_response).once.and_return(response)

    Llm::ChatClient.ask(chat, 'first', feature: :captain_agent, account: account)
    expect { Llm::ChatClient.ask(chat, 'second', feature: :captain_agent, account: account) }
      .to raise_error(described_class::DisallowedModelError, /fallback/)
  end

  it 'does not widen a captured account opt-out when a later caller allows fallbacks' do
    configure_allowlist([luna, other])
    disabled = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: false } },
                                        feature_enabled?: false)
    enabled = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: true } },
                                       feature_enabled?: false)
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = Llm::ChatClient.build(chat: context.chat(model: luna, provider: 'openrouter', assume_model_exists: true),
                                 feature: :captain_agent, model: luna, params: { models: [luna] })
    described_class.guard_chat!(feature: :captain_agent, chat: chat, account: disabled)
    described_class.guard_chat!(feature: :captain_agent, chat: chat, account: enabled)
    expect(chat.instance_variable_get(described_class::EGRESS_POLICY_IVAR)[:allow_model_fallbacks]).to be(false)

    chat.with_params(models: [luna, other])
    expect(chat.instance_variable_get(:@provider)).not_to receive(:sync_response)
    expect { chat.complete }.to raise_error(described_class::DisallowedModelError, /fallback/)
  end

  it 'allows a later opted-in account to keep an accountless chat fallback' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: true } },
                                       feature_enabled?: false)
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = Llm::ChatClient.build(chat: context.chat(model: luna, provider: 'openrouter', assume_model_exists: true),
                                 feature: :captain_agent, model: luna, params: { models: [luna] })
    response = RubyLLM::Message.new(role: :assistant, content: 'ok')
    chat.after_message { chat.params[:models] = [luna, other] }
    calls = 0
    expect(chat.instance_variable_get(:@provider)).to receive(:sync_response).twice do |_connection, payload, _headers|
      calls += 1
      expect(JSON.parse(payload.to_json).fetch('models')).to eq(calls == 1 ? [luna] : [luna, other])
      response
    end

    Llm::ChatClient.ask(chat, 'first', feature: :captain_agent, account: account)
    expect { Llm::ChatClient.ask(chat, 'second', feature: :captain_agent, account: account) }.not_to raise_error
  end

  it 'blocks an account-disabled streaming callback from replacing the selected model with another allowed model' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: false } })
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    Llm::OpenRouterRequestPolicy.tag!(chat, feature: :captain_agent, account: account, model: luna)
    chat.before_message { chat.params[:model] = other }
    described_class.guard_chat!(feature: :captain_agent, chat: chat)
    expect(chat.instance_variable_get(:@provider)).not_to receive(:stream_response)

    expect { chat.complete { |_chunk| nil } }.to raise_error(described_class::DisallowedModelError, /fallback/)
  end

  it 'permits a callback-added installation-allowed fallback for an opted-in account at the real SDK stream boundary' do
    configure_allowlist([luna, other])
    account = instance_double(Account, captain_preferences: { runtime: { openrouter_allow_model_fallbacks: true } },
                                       feature_enabled?: false)
    compiled = Llm::OpenRouterRequestCompiler.call(feature: :captain_agent, model: luna, account: account)
    expect(compiled.models).to eq([luna, other])

    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    chat.with_params(**compiled.params.merge(models: [luna]))
    Llm::OpenRouterRequestPolicy.tag!(chat, feature: :captain_agent, account: account, model: luna, routing_metadata: compiled.metadata)
    chat.before_message { chat.params[:models] << other }
    described_class.guard_chat!(feature: :captain_agent, chat: chat)
    expect(chat.instance_variable_get(:@provider)).to receive(:stream_response) do |_connection, payload, _headers|
      wire = JSON.parse(payload.to_json)
      expect(wire.fetch('models')).to eq([luna, other])
      expect(wire.fetch('provider').fetch('allow_fallbacks')).to be(true)
      RubyLLM::Message.new(role: :assistant, content: 'ok')
    end

    expect(chat.complete { |_chunk| nil }.content).to eq('ok')
  end

  it 'revalidates the model after a structured-output retry callback changes the chat' do
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    provider = chat.instance_variable_get(:@provider)
    chat.instance_variable_set(Llm::StructuredOutputPolicy::CHAT_SCHEMA_IVAR, Captain::ResponseSchema)
    chat.after_message { chat.with_params(model: other) }
    expect(provider).to receive(:sync_response).once.and_return(RubyLLM::Message.new(role: :assistant, content: 'invalid json'))

    expect { Llm::ChatClient.ask(chat, 'hello', feature: :captain_agent) }
      .to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'leaves untagged Copilot wire params and its model policy unchanged' do
    expect do
      described_class.ensure_wire_models!(feature: :copilot, params: { 'model' => other, model: luna })
      described_class.ensure_allowed!(feature: :copilot, model: other)
    end.not_to raise_error
  end

  it 'permits a single serialized Luna model and an explicitly allowlisted alternative' do
    context = RubyLLM.context { |config| config.openrouter_api_key = 'test-key' }
    chat = context.chat(model: luna, provider: 'openrouter', assume_model_exists: true)
    provider = chat.instance_variable_get(:@provider)
    response = RubyLLM::Message.new(role: :assistant, content: 'ok')
    expect(provider).to receive(:sync_response).twice do |_connection, payload, _headers|
      expect(payload.to_json.scan(/"model":/).size).to eq(1)
      expect(JSON.parse(payload.to_json).fetch('model')).to eq(luna)
      response
    end

    Llm::ChatClient.ask(chat, 'hello', feature: :captain_agent)
    configure_allowlist([luna, other])
    chat.with_params(models: [luna, other])
    Llm::ChatClient.ask(chat, 'hello again', feature: :captain_agent)
  end
end
