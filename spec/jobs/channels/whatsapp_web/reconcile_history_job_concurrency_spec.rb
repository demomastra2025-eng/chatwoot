require 'rails_helper'
require 'timeout'

RSpec.describe Channels::WhatsappWeb::ReconcileHistoryJob do
  self.use_transactional_tests = false

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  it 'deduplicates a provider event racing the scan through the locked durable request marker' do
    channel = create(:channel_whatsapp_web, connection_state: 'open', lifecycle_state: 'connected')
    channel.record_provider_history_snapshot!(message_count: 2, contact_count: 1)
    Redis::Alfred.delete(described_class::CURSOR_KEY)
    clear_enqueued_jobs
    ready = Queue.new
    start = Queue.new
    workers = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          current = Channel::WhatsappWeb.find(channel.id)
          current.request_history_sync!('full', expected_provider_history_synced_at: current.provider_history_synced_at)
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.perform_now
        end
      end
    ]
    2.times { Timeout.timeout(10) { ready.pop } }
    2.times { start << true }
    workers.each { |worker| Timeout.timeout(20) { worker.value } }
    queued = enqueued_jobs.select { |job| job[:job] == Channels::WhatsappWeb::HistorySyncJob }
    expect(queued.size).to eq(1)
    expect(channel.reload.history_sync_request_pending?).to be(true)
  ensure
    2.times { start << true } if start
    workers&.each { |worker| worker.kill if worker.alive? }
  end
end
