require 'rails_helper'

RSpec.describe Llm::ModelParameters do
  let(:config) { {} }
  let(:contract) { described_class.for('provider/test') }
  before do
    allow(Llm::Models).to receive(:model_config).with('provider/test', account: nil).and_return(config)
    allow(RubyLLM.models).to receive(:find).with('provider/test').and_return(nil)
  end

  it 'hides and omits unknown parameters instead of inferring support from a model name' do
    expect(contract.metadata).to include(supports_temperature: false, reasoning_efforts: [])
    expect(contract.compile(temperature: 1, thinking: { effort: 'high' }, params: { top_p: 0.8, reasoning_effort: 'high' }))
      .to eq(params: { openrouter_omit_temperature: true })
    expect(contract.normalize_config(model: 'provider/test', temperature: 0.5, thinking_effort: 'high')).to eq('model' => 'provider/test')
  end

  context 'with explicit installed provider metadata' do
    let(:config) do
      { 'supported_parameters' => %w[temperature top_p reasoning], 'capabilities' => ['reasoning'],
        'reasoning' => { 'supported_efforts' => %w[none low high], 'mandatory' => false } }
    end

    it 'uses the same confirmed values for UI, saved settings, and outbound request compilation' do
      expect(contract.metadata).to include(supports_temperature: true, reasoning_efforts: %w[none low high])
      expect(contract.compile(temperature: '0.4', thinking: { effort: 'high' }, params: { top_p: 0.8, unknown: true }))
        .to eq(temperature: 0.4, thinking: { effort: 'high' }, params: { top_p: 0.8 })
      expect(contract.normalize_config(temperature: 0.4, thinking_effort: 'high')).to include('temperature' => 0.4, 'thinking_effort' => 'high')
      expect(contract.compile(temperature: -1, thinking: { effort: 'medium' })).to eq(params: { openrouter_omit_temperature: true })
    end
  end

  it 'does not invent effort values from a reasoning capability alone' do
    allow(Llm::Models).to receive(:model_config).and_return('capabilities' => ['reasoning'], 'supported_parameters' => ['reasoning'])
    expect(contract.reasoning_efforts).to eq([])
  end

  it 'accepts the documented null effort contract but omits unsupported disabling for mandatory reasoning' do
    allow(Llm::Models).to receive(:model_config).and_return(
      'provider' => 'openrouter', 'source' => 'openrouter_api', 'supported_parameters' => ['reasoning'],
      'reasoning' => { 'supported_efforts' => nil, 'mandatory' => true }
    )
    expect(contract.reasoning_efforts).to eq(%w[minimal low medium high xhigh max])
    expect(contract.compile(thinking: { effort: 'max' })).to include(thinking: { effort: 'max' })
    expect(contract.compile(thinking: { effort: 'none' })).not_to have_key(:thinking)
  end

  it 'does not apply the OpenRouter null convention to an unidentified provider' do
    allow(Llm::Models).to receive(:model_config).and_return(
      'supported_parameters' => ['reasoning'], 'reasoning' => { 'supported_efforts' => nil }
    )
    expect(contract.reasoning_efforts).to eq([])
  end
end
