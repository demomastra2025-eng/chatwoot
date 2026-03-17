require 'rails_helper'

describe AgentBots::FlowBuilder::ConfigNormalizer do
  describe '.normalize' do
    it 'returns a default graph config for blank values' do
      config = described_class.normalize(nil)

      expect(config['version']).to eq(2)
      expect(config.dig('flow', 'drawflow', 'Home', 'data')).to include('trigger_root')
      expect(config.dig('flow', 'drawflow', 'Home', 'data', 'trigger_root', 'name')).to eq('trigger')
    end

    it 'converts legacy linear steps into a graph config' do
      legacy_config = {
        trigger: { event: 'keyword', keywords: ['support'] },
        steps: [
          {
            id: 'welcome',
            type: 'message',
            body: 'Hello there'
          },
          {
            id: 'menu',
            type: 'menu',
            body: 'Choose a team',
            options: [
              { label: 'Sales', value: 'sales', target_step_id: 'sales' },
              { label: 'Support', value: 'support' }
            ]
          },
          {
            id: 'sales',
            type: 'message',
            body: 'Sales branch'
          }
        ]
      }

      config = described_class.normalize(legacy_config)
      data = config.dig('flow', 'drawflow', 'Home', 'data')

      expect(data['trigger_root']['data']['event']).to eq('keyword')
      expect(data['welcome']['outputs']['output_1']['connections']).to include(
        { 'node' => 'menu', 'output' => 'input_1' }
      )
      expect(data['menu']['outputs']['output_1']['connections']).to include(
        { 'node' => 'sales', 'output' => 'input_1' }
      )
      expect(data['menu']['outputs']['output_2']['connections']).to include(
        { 'node' => 'sales', 'output' => 'input_1' }
      )
    end
  end
end
