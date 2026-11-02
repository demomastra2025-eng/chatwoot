require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::MediaAttachmentBackfillJob do
  let(:channel) { create(:channel_whatsapp_web) }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, source_id: 'IDENTITY_MEDIA',
                     content_attributes: { imported_history: true, history_attachment: { unavailable: true, kind: 'image' } })
  end
  let(:provider) { instance_double(WhatsappWeb::Providers::EvolutionService) }
  let(:files) { [] }
  let(:record) { { key: { id: message.source_id }, message: { imageMessage: { mimetype: 'image/png', fileName: 'image.png' } } } }

  before do
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider)
    allow(provider).to receive(:fetch_message_by_source_id).and_return(record)
    allow(Tempfile).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |file| files << file if Array(args.first).first == 'whatsapp-web-media-backfill' }
    end
  end

  %i[source owner inactive inbox conversation channel deleted deleting].each do |fence|
    it "discards the fetched file if #{fence} changes during provider RPC" do
      message
      other_account = create(:account)
      other_channel = create(:channel_whatsapp_web, account: channel.account)
      other_conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      allow(provider).to receive(:fetch_message_media) do
        case fence
        when :source then message.update!(source_id: 'CHANGED_SOURCE')
        when :owner then message.update!(account_id: other_account.id)
        when :inactive then channel.account.update!(status: :suspended)
        when :inbox then message.update!(inbox_id: other_channel.inbox.id)
        when :conversation then message.update!(conversation_id: other_conversation.id)
        when :channel then channel.inbox.update!(channel: other_channel)
        when :deleted then message.update!(content_attributes: message.content_attributes.merge(deleted: true))
        when :deleting then channel.inbox.mark_pending_deletion!
        end
        { base64: Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/sample.png'))), mimetype: 'image/png' }
      end
      described_class.new.perform(channel.id, message.source_id, {}, described_class::MAX_ATTEMPTS)
      expect(message.reload.attachments).to be_empty
      expect(files.size).to eq(1)
      expect(files).to all(be_closed)
      expect(message.content_attributes['history_attachment']).not_to have_key('fetch_state')
    end
  end
end
