require 'rails_helper'

RSpec.describe Messages::VoiceCoreAttachmentTranscription do
  let(:attachment) { instance_double(Attachment, account_id: 101) }
  let(:spool) { instance_double(Telephony::VoiceCoreAudioSpool, job_id: 'a' * 32, audio_filename: 'audio.ogg') }
  let(:client) { instance_double(Telephony::VoiceCoreClient) }

  it 'reuses the client with an explicit non-call flag and keeps voice note text free of fabricated roles' do
    allow(Messages::VoiceCoreAttachmentSpool).to receive(:new).with(attachment).and_return(spool)
    allow(spool).to receive(:open).and_yield(spool)
    allow(client).to receive(:transcribe).and_return(
      'dialogue_turns' => [{ 'speaker' => 'unknown', 'text' => 'Первый тест' }, { 'speaker' => 'unknown', 'text' => 'Второй тест' }],
      'model_version' => Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256
    )

    result = described_class.new(attachment, client: client).perform
    expect(client).to have_received(:transcribe).with(account_id: 101, job_id: 'a' * 32, audio_filename: 'audio.ogg',
                                                      channel_map: {}, is_phone_call: false)
    expect(result).to eq('text' => "Первый тест\nВторой тест", 'provenance' => {
                           'provider' => 'voicecore', 'model' => Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256
                         })
  end
end
