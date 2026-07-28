require 'rails_helper'

RSpec.describe Integrations::Medelement::Configuration do
  subject(:configuration) { described_class.new(hook: hook) }

  let(:hook) do
    instance_double(
      Integrations::Hook,
      secret_settings: { 'integrator_key' => 'hook-integrator-key' },
      settings: {}
    )
  end

  describe '#integrator_key' do
    it 'uses the shared project integrator key when configured' do
      with_modified_env('MEDELEMENT_INTEGRATOR_KEY' => 'project-integrator-key') do
        expect(configuration.integrator_key).to eq('project-integrator-key')
      end
    end

    it 'falls back to the hook key for existing integrations' do
      with_modified_env('MEDELEMENT_INTEGRATOR_KEY' => nil) do
        expect(configuration.integrator_key).to eq('hook-integrator-key')
      end
    end
  end

  describe '#sync_services?' do
    it 'is enabled by default for existing hooks' do
      expect(configuration.sync_services?).to be(true)
    end

    it 'respects an explicit disabled setting' do
      allow(hook).to receive(:settings).and_return('sync_services' => false)

      expect(configuration.sync_services?).to be(false)
    end
  end
end
