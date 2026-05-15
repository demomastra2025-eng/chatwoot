require 'rails_helper'

RSpec.describe Telephony::CallRecordingTranscriptionJob do
  subject(:job) { described_class.perform_later(call_session.id) }

  let(:call_session) { create(:telephony_call_session) }
  let(:transcription_service) { instance_double(Telephony::CallRecordingTranscriptionService, perform: true) }

  it 'enqueues on the audio transcription queue' do
    expect { job }.to have_enqueued_job(described_class)
      .with(call_session.id)
      .on_queue('audio_transcription')
  end

  it 'transcribes the call session recording when performed' do
    allow(Telephony::CallRecordingTranscriptionService).to receive(:new).with(call_session).and_return(transcription_service)

    described_class.perform_now(call_session.id)

    expect(transcription_service).to have_received(:perform)
  end

  it 'does nothing when the call session is missing' do
    expect(Telephony::CallRecordingTranscriptionService).not_to receive(:new)

    described_class.perform_now(999_999)
  end
end
