# frozen_string_literal: true

require 'rails_helper'
require 'erb'
require 'yaml'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'dev hybrid Procfile' do
  let(:procfile) { Rails.root.join('Procfile.dev-hybrid').read }

  it 'isolates realtime AI voice callbacks from dashboard traffic' do
    expect(procfile).to include('voice_backend:')
    expect(procfile).to include('PIDFILE=tmp/pids/voice-server.pid')
    expect(procfile).to include('-p ${DEV_VOICE_WEB_PORT:-3003}')
  end

  it 'starts a dedicated Captain runtime Sidekiq worker' do
    expect(procfile).to include('captain_runtime_worker:')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_captain_runtime.yml')
  end

  it 'starts a dedicated ActionCable broadcast worker' do
    expect(procfile).to include('action_cable_realtime_worker:')
    expect(procfile).to include('SIDEKIQ_DB_POOL=${DEV_ACTION_CABLE_REALTIME_DB_POOL:-3}')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_action_cable_realtime.yml')
  end

  it 'keeps an ActionCable consumer in lightweight development modes' do
    config = YAML.safe_load(ERB.new(Rails.root.join('config/sidekiq.yml').read).result, permitted_classes: [Symbol])
    dedicated = YAML.safe_load(ERB.new(Rails.root.join('config/sidekiq_action_cable_realtime.yml').read).result,
                               permitted_classes: [Symbol])

    expect(config[:queues]).to include('action_cable_realtime')
    expect(dedicated[:queues]).to eq(['action_cable_realtime'])
    expect(dedicated[:concurrency]).to eq(2)
  end

  it 'starts dedicated Telegram inbound Sidekiq workers' do
    expect(procfile).to include('telegram_inbound_worker:')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_telegram_inbound.yml')
    expect(procfile).to include('telegram_personal_inbound_worker:')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_telegram_personal_inbound.yml')
  end
end
# rubocop:enable RSpec/DescribeClass
