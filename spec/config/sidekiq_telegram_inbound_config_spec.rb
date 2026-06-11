require 'rails_helper'
require 'erb'
require 'yaml'

RSpec.context 'with valid Telegram inbound Sidekiq configs' do
  it 'isolates bot webhook jobs on a bounded queue' do
    config_path = Rails.root.join('config/sidekiq_telegram_inbound.yml')

    with_modified_env(TELEGRAM_INBOUND_SIDEKIQ_CONCURRENCY: nil) do
      config = YAML.safe_load(ERB.new(config_path.read).result, permitted_classes: [Symbol])

      expect(config[:queues]).to eq(['telegram_inbound'])
      expect(config[:concurrency].to_i).to eq(2)
    end
  end

  it 'isolates Telegram Personal realtime jobs on a bounded queue' do
    config_path = Rails.root.join('config/sidekiq_telegram_personal_inbound.yml')

    with_modified_env(TELEGRAM_PERSONAL_INBOUND_SIDEKIQ_CONCURRENCY: nil) do
      config = YAML.safe_load(ERB.new(config_path.read).result, permitted_classes: [Symbol])

      expect(config[:queues]).to eq(['telegram_personal_inbound'])
      expect(config[:concurrency].to_i).to eq(2)
    end
  end
end
