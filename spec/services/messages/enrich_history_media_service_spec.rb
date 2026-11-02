require 'rails_helper'

RSpec.describe Messages::EnrichHistoryMediaService do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  let(:channel) { create(:channel_whatsapp_web) }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, source_id: 'OLD_MEDIA',
                     content: 'Original caption', created_at: 120.days.ago,
                     content_attributes: { imported_history: true, history_attachment: { unavailable: true, deferred: true, kind: 'image' } })
  end
  let(:record) do
    { key: { id: message.source_id, remoteJid: '15551234567@s.whatsapp.net' },
      message: { imageMessage: { caption: 'Original caption', mimetype: 'image/png', fileName: 'old.png' } } }
  end
  let(:provider) { instance_double(WhatsappWeb::Providers::EvolutionService) }
  let(:media) { { base64: Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/sample.png'))), mimetype: 'image/png' } }

  before do
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider)
    allow(provider).to receive(:fetch_message_by_source_id).and_return(record)
    allow(provider).to receive(:fetch_message_media).and_return(media)
  end

  it 'downloads at MAX_ATTEMPTS, preserves the caption, and makes repeat requests idempotent without runtime fanout' do
    message
    clear_enqueued_jobs
    described_class.new(message: message).perform
    described_class.new(message: message.reload).perform

    expect(provider).to have_received(:fetch_message_media).once
    expect(message.reload.attachments.count).to eq(1)
    expect(message.content).to eq('Original caption')
    expect(message.content_attributes).not_to have_key('history_attachment')
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(
      Channels::WhatsappWeb::MediaAttachmentBackfillJob, SendReplyJob, EventDispatcherJob, AutoAssignment::AssignmentJob
    )
  end

  it 'keeps unavailable media as a retryable placeholder without scheduling background retries' do
    allow(provider).to receive(:fetch_message_media).and_return(unavailable: true)
    message
    clear_enqueued_jobs
    described_class.new(message: message).perform
    expect(message.reload.attachments).to be_empty
    expect(message.content).to eq('Original caption')
    expect(message.content_attributes['history_attachment']).to include('kind' => 'image', 'fetch_state' => 'unavailable', 'deferred' => true)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(Channels::WhatsappWeb::MediaAttachmentBackfillJob, SendReplyJob)
  end

  it 'does not restore a message deleted during the provider request' do
    allow(provider).to receive(:fetch_message_media) do
      message.update!(content: 'Deleted', content_attributes: { deleted: true })
      media
    end
    described_class.new(message: message).perform
    expect(message.reload.attachments).to be_empty
    expect(message.content_attributes).to eq('deleted' => true)
  end

  it 'does not attach when the inbox is marked for deletion during the provider request' do
    allow(provider).to receive(:fetch_message_media) do
      channel.inbox.mark_pending_deletion!
      media
    end
    described_class.new(message: message).perform
    expect(message.reload.attachments).to be_empty
  end

  it 'restores the previous runtime suppression state on provider pipeline exceptions' do
    channel
    message
    allow(Channels::WhatsappWeb::MediaAttachmentBackfillJob).to receive(:new).and_raise(MutexApplicationJob::LockAcquisitionError)
    [false, true].each do |previous|
      Current.suppress_runtime_events = previous
      expect { described_class.new(message: message).perform }.to raise_error(MutexApplicationJob::LockAcquisitionError)
      expect(Current.suppress_runtime_events).to eq(previous)
    end
  ensure
    Current.suppress_runtime_events = false
  end

  it 'delegates Telegram to its existing pipeline with runtime events suppressed' do
    telegram = create(:channel_telegram_personal)
    conversation = create(:conversation, account: telegram.account, inbox: telegram.inbox)
    tg_message = create(:message, account: telegram.account, inbox: telegram.inbox, conversation: conversation, source_id: '701',
                                  content_attributes: { telegram_history_media_incomplete: true })
    service = instance_double(TelegramPersonal::EnrichHistoryMediaService)
    expect(TelegramPersonal::EnrichHistoryMediaService).to receive(:new).with(message: tg_message).and_return(service)
    expect(service).to receive(:perform) do
      expect(Current.suppress_runtime_events).to be(true)
      tg_message
    end
    expect(described_class.new(message: tg_message).perform).to eq(tg_message)
  end
end
