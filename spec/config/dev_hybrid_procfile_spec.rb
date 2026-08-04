# frozen_string_literal: true

require 'rails_helper'

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

  it 'starts dedicated Telegram inbound Sidekiq workers' do
    expect(procfile).to include('telegram_inbound_worker:')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_telegram_inbound.yml')
    expect(procfile).to include('telegram_personal_inbound_worker:')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_telegram_personal_inbound.yml')
  end
end
# rubocop:enable RSpec/DescribeClass
