require 'rails_helper'

RSpec.describe Telephony::VoiceCoreRecordingTranscription do
  let(:session) { instance_double(Telephony::CallSession, account_id: 101, metadata: { 'recording' => { 'channel_map' => channel_map } }) }
  let(:channel_map) { { 'FL' => 'client', 'FR' => 'operator' } }
  let(:spool) { instance_double(Telephony::VoiceCoreRecordingSpool, job_id: 'a' * 32, audio_filename: 'audio.wav') }
  let(:client) { instance_double(Telephony::VoiceCoreClient) }
  let(:response) do
    { 'dialogue_turns' => [{ 'speaker' => 'client', 'channel' => 0, 'start_sec' => 0.25, 'end_sec' => 1.5, 'text' => 'Тест' }],
      'language' => 'ru', 'duration_sec' => 2.0, 'channels' => 2, 'channel_status' => 'mapped', 'model_version' => 'b' * 64 }
  end

  before do
    allow(Telephony::VoiceCoreRecordingSpool).to receive(:new).with(session).and_return(spool)
    allow(spool).to receive(:open).and_yield(spool)
    allow(client).to receive(:transcribe).and_return(response)
  end

  it 'passes the canonical reversed channel map and retains native structured turns and provenance' do
    result = described_class.new(session, client: client).perform

    expect(client).to have_received(:transcribe).with(account_id: 101, job_id: 'a' * 32, audio_filename: 'audio.wav',
                                                      channel_map: { '0' => 'client', '1' => 'operator' })
    expect(result['transcript_items'].first).to include('speaker' => 'client', 'start_sec' => 0.25, 'end_sec' => 1.5, 'channel' => 0)
    expect(result['voicecore']).to include('model_version' => 'b' * 64, 'channel_status' => 'mapped')
  end

  it 'handles zero-based and one-based numeric maps without guessing mixed conventions' do
    [{ '0' => 'operator', '1' => 'client' }, { '1' => 'operator', '2' => 'client' }].each do |map|
      allow(session).to receive(:metadata).and_return('recording' => { 'channel_map' => map })
      described_class.new(session, client: client).perform
      expect(client).to have_received(:transcribe).with(hash_including(channel_map: { '0' => 'operator', '1' => 'client' }))
    end
    allow(session).to receive(:metadata).and_return('recording' => { 'channel_map' => { '0' => 'operator', '1' => 'client', '2' => 'operator' } })
    described_class.new(session, client: client).perform
    expect(client).to have_received(:transcribe).with(hash_including(channel_map: {}))
  end

  it 'keeps unknown turns for both unmapped channels without inventing an operator' do
    allow(client).to receive(:transcribe).and_return(response.merge(
                                                       'channel_status' => 'unmapped', 'dialogue_turns' => [
                                                         { 'speaker' => 'unknown', 'channel' => 0, 'start_sec' => 0.1, 'end_sec' => 0.3,
                                                           'text' => 'Да' },
                                                         { 'speaker' => 'unknown', 'channel' => 1, 'start_sec' => 0.2, 'end_sec' => 0.4,
                                                           'text' => 'Нет' }
                                                       ]
                                                     ))
    result = described_class.new(session, client: client).perform
    expect(result['transcript_items'].pluck('speaker')).to eq(%w[unknown unknown])
    expect(result['transcript_items'].pluck('channel')).to eq([0, 1])
    expect(result['text']).to include('Да', 'Нет', 'Говорящий')
    expect(result['text']).not_to include('Сотрудник')
  end

  it 'does not guess when map aliases conflict or a role is missing' do
    [{ 'FL' => 'client' }, { 'FL' => 'client', 'channel_1' => 'operator', 'FR' => 'operator' }].each do |map|
      allow(session).to receive(:metadata).and_return('recording' => { 'channel_map' => map })
      described_class.new(session, client: client).perform
    end
    expect(client).to have_received(:transcribe).with(hash_including(channel_map: {})).twice
  end

  it 'represents successfully decoded silence without inventing speech or a paid summary' do
    allow(client).to receive(:transcribe).and_return(response.merge('dialogue_turns' => []))
    result = described_class.new(session, client: client).perform
    expect(result).to include('text' => '', 'transcript_items' => [], 'outcome' => 'no_answer', 'summary' => 'Речь в записи не обнаружена.')
  end
end
