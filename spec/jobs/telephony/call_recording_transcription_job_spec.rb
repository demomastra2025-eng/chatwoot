require 'rails_helper'

RSpec.describe Telephony::CallRecordingTranscriptionJob do
  subject(:job) { described_class.perform_later(call_session.id) }

  let(:call_session) { create(:telephony_call_session) }
  let(:transcription_service) { instance_double(Telephony::CallRecordingTranscriptionService, perform: true) }

  it 'enqueues on the isolated voice recording transcription queue' do
    expect { job }.to have_enqueued_job(described_class)
      .with(call_session.id)
      .on_queue('voice_recording_transcription')
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

  it 'retries a transient statement timeout while another call update holds the session row' do
    allow(Telephony::CallRecordingTranscriptionService).to receive(:new).and_raise(ActiveRecord::QueryCanceled, 'statement timeout')

    expect { described_class.perform_now(call_session.id) }.to have_enqueued_job(described_class).with(call_session.id)
  end

  it 'retries a local provider timeout without calling a different provider' do
    allow(Telephony::CallRecordingTranscriptionService).to receive(:new).and_return(transcription_service)
    allow(transcription_service).to receive(:perform).and_return(
      error: 'VoiceCore transcription unavailable', error_code: 'unavailable', retryable: true
    )

    expect { described_class.perform_now(call_session.id) }.to have_enqueued_job(described_class).with(call_session.id)
  end

  it 'does not retry a terminal local schema or authentication error' do
    allow(Telephony::CallRecordingTranscriptionService).to receive(:new).and_return(transcription_service)
    allow(transcription_service).to receive(:perform).and_return(
      error: 'VoiceCore transcription unavailable', error_code: 'invalid_response', retryable: false
    )

    expect { described_class.perform_now(call_session.id) }.not_to have_enqueued_job(described_class)
  end
end
