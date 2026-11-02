require 'rails_helper'
require 'timeout'

RSpec.describe TelegramPersonal::EnrichHistoryMediaService do
  self.use_transactional_tests = false

  let(:channel) { create(:channel_telegram_personal) }
  let(:contact) { create(:contact, account: channel.account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '15550000004') }
  let(:conversation) do
    create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox,
                          additional_attributes: { chat_id: '15550000004', peer_user_id: '15550000004' })
  end
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, source_id: '900', content: 'Original caption',
                     content_attributes: { imported_history: true, telegram_history_media_incomplete: true })
  end
  let(:downloaded_files) { [] }
  let(:gateway) { instance_double(TelegramPersonal::GatewayClient) }
  let(:attachment) { { kind: 'photo', telegram_message_id: '900', url: 'https://media.example.test/900.png' } }
  let(:payload) do
    { message_id: '900', chat_id: '15550000004', peer_user_id: '15550000004', sender_id: '15550000004', chat_type: 'private',
      attachments: [attachment] }
  end

  before do
    allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway)
    allow(gateway).to receive(:enrich_message_media!).and_return(payload: payload)
    allow(Down).to receive(:download) { image_file }
  end

  def image_file
    Tempfile.new(['tg-history-safety', '.png']).tap do |file|
      file.binmode
      file.write(File.binread(Rails.root.join('spec/assets/sample.png')))
      file.rewind
      file.define_singleton_method(:original_filename) { 'photo.png' }
      file.define_singleton_method(:content_type) { 'image/png' }
      downloaded_files << file
    end
  end

  it 'downloads outside SQL and suppresses runtime events through cleanup' do
    message
    clear_enqueued_jobs
    expect(Down).to receive(:download) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      expect(Current.suppress_runtime_events).to be(true)
      image_file
    end
    described_class.new(message: message).perform
    expect(message.reload.attachments.count).to eq(1)
    expect(downloaded_files).to all(be_closed)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(SendReplyJob, EventDispatcherJob, AutoAssignment::AssignmentJob)
  end

  %i[message inbox account source ids channel channel_owner].each do |fence|
    it "does not attach after the #{fence} fence changes during the remote download" do
      message
      original_attributes = message.content_attributes.deep_dup
      alternate_channel = create(:channel_telegram_personal, account: channel.account) if fence == :channel
      alternate_account = create(:account) if fence == :channel_owner
      previous_suppression = Current.suppress_runtime_events
      allow(Down).to receive(:download) do
        case fence
        when :message then message.update!(content_attributes: message.content_attributes.merge(deleted: true))
        when :inbox then channel.inbox.mark_pending_deletion!
        when :account then channel.account.update!(status: :suspended)
        when :source then message.update!(source_id: 'OTHER')
        when :ids then message.update!(content_attributes: message.content_attributes.merge(telegram_history_media_skipped_message_ids: ['999']))
        when :channel then channel.inbox.update_columns(channel_id: alternate_channel.id) # rubocop:disable Rails/SkipsModelValidations
        when :channel_owner then channel.update_columns(account_id: alternate_account.id) # rubocop:disable Rails/SkipsModelValidations
        end
        image_file
      end
      if fence == :ids
        described_class.new(message: message).perform
      else
        expect { described_class.new(message: message).perform }.to raise_error(described_class::Error, 'history_media_unavailable')
      end
      expect(message.reload.attachments).to be_empty
      expect(message.content_attributes).to eq(original_attributes) if %i[channel channel_owner].include?(fence)
      expect(downloaded_files.size).to eq(1)
      expect(downloaded_files).to all(be_closed)
      expect(Current.suppress_runtime_events).to eq(previous_suppression)
    end
  end

  it 'keeps a partial album incomplete until every requested provider ID has an attachment' do
    message.update!(content_attributes: message.content_attributes.merge(telegram_message_ids: %w[900 901],
                                                                         telegram_history_media_skipped_message_ids: %w[
                                                                           900 901
                                                                         ]))
    allow(gateway).to receive(:enrich_message_media!).and_return(payload: payload)
    described_class.new(message: message).perform
    expect(message.reload.content_attributes).to include('telegram_history_media_incomplete' => true,
                                                         'telegram_history_media_skipped_message_ids' => ['901'])
    expect(message.attachments.count).to eq(1)
    allow(gateway).to receive(:enrich_message_media!).and_return(payload: payload.merge(attachments: [attachment.merge(telegram_message_id: '901')]))
    described_class.new(message: message).perform
    expect(message.reload.attachments.count).to eq(2)
    expect(message.content_attributes).not_to have_key('telegram_history_media_incomplete')
    expect(message.content).to eq('Original caption')
  end

  it 'does not download a known album ID that was outside the requested skipped IDs' do
    message.update!(content_attributes: message.content_attributes.merge(telegram_message_ids: %w[900 901],
                                                                         telegram_history_media_skipped_message_ids: ['901']))
    expect(Down).not_to receive(:download)
    described_class.new(message: message).perform
    expect(message.reload.attachments).to be_empty
    expect(message.content_attributes['telegram_history_media_incomplete']).to be(true)
  end

  it 'deduplicates concurrent downloads by provider ID under the final lock' do
    message
    ready = Queue.new
    proceed = Queue.new
    allow(Down).to receive(:download) do
      ready << true
      proceed.pop
      image_file
    end
    workers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { described_class.new(message: Message.find(message.id)).perform }
      end
    end
    2.times { Timeout.timeout(10) { ready.pop } }
    2.times { proceed << true }
    workers.each { |worker| Timeout.timeout(20) { worker.value } }
    expect(message.reload.attachments.count).to eq(1)
    expect(downloaded_files).to all(be_closed)
  ensure
    2.times { proceed << true } if proceed
    workers&.each { |worker| worker.kill if worker.alive? }
  end
end
