require 'rails_helper'
require 'timeout'

RSpec.describe Messages::EnrichHistoryMediaService do
  self.use_transactional_tests = false

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  it 'keeps provider RPC outside SQL transactions and deduplicates simultaneous reads' do
    channel = create(:channel_whatsapp_web)
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
    message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, source_id: 'RACING_MEDIA',
                               content_attributes: { imported_history: true, history_attachment: { unavailable: true } })
    provider = instance_double(WhatsappWeb::Providers::EvolutionService)
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider)
    allow(provider).to receive(:fetch_message_by_source_id).and_return(
      key: { id: message.source_id }, message: { imageMessage: { mimetype: 'image/png', fileName: 'old.png' } }
    )
    ready = Queue.new
    proceed = Queue.new
    observed_transactions = Queue.new
    allow(provider).to receive(:fetch_message_media) do
      observed_transactions << ActiveRecord::Base.connection.open_transactions
      ready << true
      proceed.pop
      { base64: Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/sample.png'))), mimetype: 'image/png' }
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(message: Message.find(message.id)).perform
      end
    end
    Timeout.timeout(10) { ready.pop }
    expect { described_class.new(message: message.reload).perform }.to raise_error(MutexApplicationJob::LockAcquisitionError)
    proceed << true
    Timeout.timeout(20) { worker.value }
    described_class.new(message: message.reload).perform
    expect(observed_transactions.pop).to eq(0)
    expect(provider).to have_received(:fetch_message_media).once
    expect(message.reload.attachments.count).to eq(1)
  ensure
    proceed << true if proceed
    worker&.kill if worker&.alive?
  end

  it 'still attaches once if the Redis download lease is lost during two provider requests' do
    channel = create(:channel_whatsapp_web)
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
    message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, source_id: 'LOST_MEDIA_LEASE',
                               content_attributes: { imported_history: true, history_attachment: { unavailable: true } })
    provider = instance_double(WhatsappWeb::Providers::EvolutionService)
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider)
    allow(provider).to receive(:fetch_message_by_source_id).and_return(
      key: { id: message.source_id }, message: { imageMessage: { mimetype: 'image/png', fileName: 'old.png' } }
    )
    ready = Queue.new
    proceed = Queue.new
    allow(provider).to receive(:fetch_message_media) do
      ready << true
      proceed.pop
      { base64: Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/sample.png'))), mimetype: 'image/png' }
    end
    request = lambda do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.new(message: Message.find(message.id)).perform
        end
      end
    end
    workers = [request.call]
    Timeout.timeout(10) { ready.pop }
    Redis::Alfred.delete("WHATSAPP_WEB_MEDIA_BACKFILL_MUTEX::#{channel.id}::#{Digest::SHA256.hexdigest(message.source_id)}")
    workers << request.call
    Timeout.timeout(10) { ready.pop }
    2.times { proceed << true }
    workers.each { |worker| Timeout.timeout(20) { worker.value } }
    expect(provider).to have_received(:fetch_message_media).twice
    expect(message.reload.attachments.count).to eq(1)
  ensure
    2.times { proceed << true } if proceed
    workers&.each { |worker| worker.kill if worker.alive? }
  end
end
