# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Storage::VoiceRecordingRemoteStorage do
  let(:fake_service) { instance_double(ActiveStorage::Service) }
  let(:temp_file) { Tempfile.new(['sample', '.mp3']) }

  before do
    temp_file.write('mp3-binary-payload')
    temp_file.flush
    allow(ActiveStorage::Blob).to receive(:service).and_return(fake_service)
  end

  after do
    temp_file.close!
  end

  describe '.enabled?' do
    it 'returns true when active_storage.service is s3_compatible' do
      allow(Rails.configuration.active_storage).to receive(:service).and_return(:s3_compatible)
      expect(described_class.enabled?).to be(true)
    end

    it 'returns false when active_storage.service is local' do
      allow(Rails.configuration.active_storage).to receive(:service).and_return(:local)
      expect(described_class.enabled?).to be(false)
    end
  end

  describe '.upload_file and .delete_key' do
    before do
      allow(Rails.configuration.active_storage).to receive(:service).and_return(:s3_compatible)
    end

    it 'uploads a valid voice-recordings key and deletes it on request' do
      allow(fake_service).to receive(:upload)
      allow(fake_service).to receive(:delete)

      expect(
        described_class.upload_file('voice-recordings/sipuni/43/1/sample.mp3', temp_file.path, content_type: 'audio/mpeg')
      ).to be(true)
      expect(fake_service).to have_received(:upload).with(
        'voice-recordings/sipuni/43/1/sample.mp3',
        anything,
        hash_including(content_type: 'audio/mpeg')
      )

      expect(described_class.delete_key('voice-recordings/sipuni/43/1/sample.wav')).to be(true)
      expect(fake_service).to have_received(:delete).with('voice-recordings/sipuni/43/1/sample.wav')
    end

    it 'never uploads raw .wav files to S3 so only compressed recordings are stored remotely' do
      allow(fake_service).to receive(:upload)
      expect(
        described_class.upload_file('voice-recordings/asterisk/43/1/raw.wav', temp_file.path, content_type: 'audio/wav')
      ).to be(false)
      expect(fake_service).not_to have_received(:upload)
    end

    it 'rejects keys outside voice-recordings/' do
      expect(described_class.upload_file('../outside.mp3', temp_file.path)).to be(false)
      expect(described_class.delete_key('other-prefix/file.wav')).to be(false)
    end
  end

  describe '.url_for' do
    before do
      allow(Rails.configuration.active_storage).to receive(:service).and_return(:s3_compatible)
    end

    it 'returns a signed inline URL when the key exists in S3' do
      key = 'voice-recordings/sipuni/43/1/sample.mp3'
      allow(fake_service).to receive(:exist?).with(key).and_return(true)
      allow(fake_service).to receive(:url).and_return('https://object.pscloud.io/psi-camelopardalis/signed')

      url = described_class.url_for(key, filename: 'sample.mp3', content_type: 'audio/mpeg')
      expect(url).to eq('https://object.pscloud.io/psi-camelopardalis/signed')
    end
  end
end
