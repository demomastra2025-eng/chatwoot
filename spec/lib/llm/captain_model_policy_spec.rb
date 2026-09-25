# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CaptainModelPolicy do
  let(:luna) { 'openai/gpt-5.6-luna' }
  let(:other) { 'openai/gpt-5.4' }

  def configure_allowlist(value)
    allow(InstallationConfig).to receive(:find_by).and_call_original
    allow(InstallationConfig).to receive(:find_by).with(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').and_return(double(value: value))
  end

  it 'allows only Luna by default for Captain and leaves Copilot unaffected' do
    expect(described_class.allowed_models).to eq([luna])
    expect { described_class.ensure_allowed!(feature: :assistant, model: luna) }.not_to raise_error
    expect { described_class.ensure_allowed!(feature: :captain_agent, model: other) }
      .to raise_error(described_class::DisallowedModelError)
    expect { described_class.ensure_allowed!(feature: :copilot, model: other) }.not_to raise_error
  end

  it 'fails closed on an invalid or empty explicit installation allowlist' do
    configure_allowlist('{invalid json')
    expect { described_class.ensure_allowed!(feature: :captain, model: luna) }
      .to raise_error(described_class::DisallowedModelError)

    configure_allowlist([])
    expect { described_class.ensure_allowed!(feature: :assistant, model: luna) }
      .to raise_error(described_class::DisallowedModelError)
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

  it 'filters implicit OpenRouter fallback routing without leaking non-allowlisted models' do
    route = Llm::OpenRouterRoutingProfile.for(feature: :assistant, model: luna)
    expect(route.models).to eq([luna])
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

  it 'does not permit caller-supplied wire model and models to replace a validated route' do
    request = Struct.new(:feature_key, :models, :options, keyword_init: true).new(
      feature_key: 'captain_agent', models: [luna], options: {}
    )
    compiled = Llm::OpenRouterRequestCompiler.call(
      request: request, model: luna,
      base_params: { model: other, 'models' => [other], 'model' => other, models: [other] }
    )
    expect(compiled.model).to eq(luna)
    expect(compiled.params[:models]).to eq([luna])
    expect(compiled.params).not_to include(:model, 'model', 'models')
  end

  it 'rejects prebuilt and mutated Captain chats even when an allowed option was supplied' do
    chat = double(model: double(id: other))
    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna)
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
    Llm::OpenRouterRequestPolicy.tag!(chat, feature: :captain_agent, model: luna)
    expect do
      Llm::ChatClient.ask(chat, 'customer message', model: luna)
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
  end

  it 'rejects direct ChatClient wire overrides before build and rechecks params before ask' do
    chat = double(model: double(id: luna), params: { 'models' => [luna, other] })

    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna, params: { models: [other] })
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
    expect do
      Llm::ChatClient.build(chat: chat, feature: :captain_agent, model: luna, params: { 'model' => other })
    end.to raise_error(described_class::DisallowedModelError, /gpt-5.4/)
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
end
