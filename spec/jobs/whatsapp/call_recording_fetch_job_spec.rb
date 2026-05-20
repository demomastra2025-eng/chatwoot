require 'rails_helper'

RSpec.describe Whatsapp::CallRecordingFetchJob, type: :job do
  let(:account) { create(:account) }
  let(:call) { create(:call, account: account, status: 'completed', media_session_id: 'session-recorded') }
  let(:client) { instance_double(Whatsapp::MediaServerClient) }

  before do
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(client)
    allow(client).to receive(:terminate_session).with(call.media_session_id).and_return(true)
    allow(Whatsapp::CallMessageBuilder).to receive(:update_recording_url!)
    allow(Whatsapp::CallTranscriptionJob).to receive(:perform_later)
  end

  it 'runs on the isolated WhatsApp calls queue' do
    expect(described_class.queue_name).to eq('whatsapp_calls')
  end

  it 'does not hit the media server again when the recording is already attached' do
    call.recording.attach(io: StringIO.new('existing-recording'), filename: 'existing.ogg', content_type: 'audio/ogg')

    expect(client).not_to receive(:terminate_session)
    expect(client).not_to receive(:download_recording)

    described_class.perform_now(call.id)

    expect(Whatsapp::CallMessageBuilder).not_to have_received(:update_recording_url!)
  end

  it 'attaches a mixed recording from side recordings when combined recording is missing' do
    allow(client).to receive(:download_recording).with(call.media_session_id).and_raise(
      Whatsapp::MediaServerClient::SessionError.new('Recording download failed (404)', http_status: 404)
    )
    allow(client).to receive(:download_recording).with(call.media_session_id, side: :customer).and_return('customer-ogg' * 80)
    allow(client).to receive(:download_recording).with(call.media_session_id, side: :agent).and_return('agent-ogg' * 80)
    allow(Open3).to receive(:capture3) do |*cmd|
      File.binwrite(cmd.last, 'mixed-ogg' * 100)
      ['', '', instance_double(Process::Status, success?: true)]
    end

    described_class.perform_now(call.id)

    expect(call.reload.recording).to be_attached
    expect(call.recording.blob.byte_size).to eq(('mixed-ogg' * 100).bytesize)
    expect(Whatsapp::CallMessageBuilder).to have_received(:update_recording_url!).with(call: call)
    expect(Whatsapp::CallTranscriptionJob).to have_received(:perform_later).with(call.id)
    expect(Open3).to have_received(:capture3).with(
      'ffmpeg', '-y', '-loglevel', 'error',
      '-i', kind_of(String), '-i', kind_of(String),
      '-filter_complex', '[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0[aout]',
      '-map', '[aout]', '-c:a', 'libopus', '-b:a', '48000', '-ar', '48000', '-ac', '1', kind_of(String)
    )
  end

  it 'does not attach header-only side recordings' do
    allow(client).to receive(:download_recording).with(call.media_session_id).and_raise(
      Whatsapp::MediaServerClient::SessionError.new('Recording download failed (404)', http_status: 404)
    )
    allow(client).to receive(:download_recording).with(call.media_session_id, side: :customer).and_return('x' * 96)
    allow(client).to receive(:download_recording).with(call.media_session_id, side: :agent).and_return('y' * 96)

    described_class.perform_now(call.id)

    expect(call.reload.recording).not_to be_attached
    expect(Whatsapp::CallMessageBuilder).not_to have_received(:update_recording_url!)
    expect(Whatsapp::CallTranscriptionJob).not_to have_received(:perform_later)
  end
end
