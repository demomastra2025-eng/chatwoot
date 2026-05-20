require 'rails_helper'
require 'erb'
require 'yaml'

RSpec.context 'with valid WhatsApp calls Sidekiq config' do
  let(:config_path) { Rails.root.join('config/sidekiq_whatsapp_calls.yml') }

  it 'isolates post-call jobs on a bounded queue' do
    with_modified_env(WHATSAPP_CALLS_SIDEKIQ_CONCURRENCY: nil) do
      config = YAML.safe_load(ERB.new(config_path.read).result, permitted_classes: [Symbol])

      expect(config[:queues]).to eq(['whatsapp_calls'])
      expect(config[:concurrency].to_i).to eq(1)
    end
  end
end
