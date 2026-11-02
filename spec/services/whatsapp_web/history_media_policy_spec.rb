require 'rails_helper'

RSpec.describe WhatsappWeb::HistoryMediaPolicy do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  it 'downloads automatically through exactly 90 days and defers older media' do
    freeze_time do
      expect(described_class.deferred?(90.days.ago)).to be(false)
      expect(described_class.deferred?(90.days.ago - 1.second)).to be(true)
    end
  end

  it 'keeps old text, type and caption while skipping base64, provider and remote downloads', :aggregate_failures do
    channel = create(:channel_whatsapp_web)
    expect(Down).not_to receive(:download)
    expect(WhatsappWeb::MediaDecryptor).not_to receive(:decrypt_remote_media)
    expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
    records = [
      { key: { id: 'OLD_PHOTO', remoteJid: '15551234567@s.whatsapp.net', fromMe: false }, messageTimestamp: 91.days.ago.to_i,
        message: { imageMessage: { caption: 'Historical caption', mimetype: 'image/png', fileName: 'old.png',
                                   base64: Base64.strict_encode64('old bytes'), url: 'https://mmg.whatsapp.net/old.enc' } } },
      { key: { id: 'OLD_AUDIO', remoteJid: '15551234567@s.whatsapp.net', fromMe: false }, messageTimestamp: 91.days.ago.to_i,
        message: { audioMessage: { mimetype: 'audio/ogg', url: 'https://mmg.whatsapp.net/old-audio.enc' } } }
    ]
    WhatsappWeb::HistoryImportService.new(channel: channel, records: records).perform
    photo = channel.inbox.messages.find_by!(source_id: 'OLD_PHOTO')
    audio = channel.inbox.messages.find_by!(source_id: 'OLD_AUDIO')
    expect(photo.content).to eq('Historical caption')
    expect(audio.content).to eq('[Attachment]')
    expect(photo.content_attributes['history_attachment']).to include('kind' => 'image', 'deferred' => true, 'unavailable' => true)
    expect(audio.content_attributes['history_attachment']).to include('kind' => 'audio', 'deferred' => true)
    expect(photo.attachments).to be_empty
    expect(audio.attachments).to be_empty
  end
end
