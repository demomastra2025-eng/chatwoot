# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'telephony:compress_recordings rake task' do
  let(:task) { Rake::Task['telephony:compress_recordings'] }
  let(:account) { create(:account) }
  let(:recording_file) do
    Tempfile.new(['synthetic-recording', '.wav']).tap do |file|
      file.write('synthetic recording bytes')
      file.flush
    end
  end

  before do
    Rails.application.load_tasks unless Rake::Task.tasks.any? { |candidate| candidate.name == 'telephony:compress_recordings' }
    task.reenable
  end

  after do
    recording_file.close!
  end

  it 'defaults to a bounded, account-scoped dry run and prints a resume cursor' do
    first, second = Array.new(2) do |index|
      create(:telephony_call_session, account: account, recording_ref: "voice-recordings/sipuni/#{account.id}/old-#{index}.wav")
    end
    create(:telephony_call_session, recording_ref: 'voice-recordings/sipuni/other/old.wav')
    expect(Storage::RecordingPaths).to receive(:resolve).with(second.recording_ref, account_id: account.id)
      .once.and_return(Pathname.new(recording_file.path))
    expect(Telephony::RecordingCompressionService).not_to receive(:compress)

    expect { task.invoke(account.id.to_s, nil, '1', first.id.to_s) }
      .to output(/DRY RUN: nothing is changed.*Recordings that would be processed: 1.*Resume after call session id: #{second.id}/m).to_stdout
  end

  it 'compresses only after explicit opt-in and remains account-scoped' do
    session = create(:telephony_call_session, account: account, recording_ref: "voice-recordings/sipuni/#{account.id}/selected.wav")
    create(:telephony_call_session, recording_ref: 'voice-recordings/sipuni/other/selected.wav')
    allow(Storage::RecordingPaths).to receive(:resolve).with(session.recording_ref, account_id: account.id)
      .and_return(Pathname.new(recording_file.path))
    expect(Telephony::RecordingCompressionService).to receive(:compress).with(call_session: session)
      .and_return(success: true, compressed_bytes: 12)

    expect { task.invoke(account.id.to_s, 'false', '50', '0') }
      .to output(/LIVE RUN: original WAV files remain available for 30 days.*Recordings processed: 1/m).to_stdout
  end
end
