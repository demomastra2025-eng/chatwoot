require 'rails_helper'

RSpec.describe Telephony::CallRecordingTranscriptionService, type: :service do
  let(:account) do
    create(
      :account,
      audio_transcriptions: false,
      call_transcriptions: true
    )
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:voice_message) do
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      content_type: :voice_call,
      source_id: 'voice_call:operator-call-1',
      content_attributes: { 'data' => { 'status' => 'completed' } }
    )
  end
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      external_call_ref: 'operator-call-1',
      status: 'completed',
      direction: 'inbound',
      recording_ref: 'rec_operator_1',
      metadata: {
        'recording' => {
          'recording_ref' => 'rec_operator_1',
          'storage_key' => 'voice-recordings/1/operator-call-1/recording.wav',
          'content_type' => 'audio/wav',
          'source' => 'onelink_runtime'
        },
        'metadata' => { 'routing_mode' => 'operator' }
      }
    )
  end
  let(:transcript) { 'Клиент: Сәлеметсіз бе, можно записаться?\nОператор: Иә, әрине.' }
  let(:recording_path) { Rails.root.join('storage/voice-recordings/1/operator-call-1/recording.wav') }
  let(:response) { described_class::TranscriptionResult.new(text: transcript) }

  before do
    voice_message
    FileUtils.mkdir_p(recording_path.dirname)
    File.binwrite(recording_path, "RIFF\x24\x00\x00\x00WAVEfmt ")
    allow(Llm::Config).to receive(:provider_for_model).and_return('openai')
    allow(Llm::Config).to receive(:api_key).and_return('test-key')
    allow(Llm::Config).to receive(:api_base).and_return(nil)
    allow(Llm::Config).to receive(:with_api_key).and_yield(:llm_context)
    allow(Llm::Runtime).to receive(:transcribe).and_return(response)
  end

  after do
    FileUtils.rm_f(recording_path)
  end

  it 'transcribes a stored call recording into the native voice call bubble' do
    result = described_class.new(call_session).perform

    expect(result).to include(success: true, transcript: transcript)
    expect(Llm::Runtime).to have_received(:transcribe).with(
      hash_including(
        feature: :audio_transcription,
        account: account,
        input: recording_path.to_s,
        options: { temperature: 0.2 }
      )
    )

    call_session.reload
    expect(call_session.transcript_ref).to eq('call_recording_transcript:operator-call-1')
    expect(call_session.metadata.dig('recording', 'transcription')).to include('status' => 'completed', 'text' => transcript)

    data = voice_message.reload.content_attributes['data']
    expect(data['transcript_ref']).to eq('call_recording_transcript:operator-call-1')
    expect(data['transcript']).to eq(transcript)
    expect(data['recording']).to include('storage_key' => 'voice-recordings/1/operator-call-1/recording.wav')
  end

  it 'persists structured dialogue, summary and probed channel data on the call and message' do
    allow(Telephony::CallTranscript).to receive(:probe).and_return(
      'channels' => 2, 'channel_layout' => 'stereo', 'duration_seconds' => 12.5
    )
    allow(Llm::Runtime).to receive(:transcribe).and_return(
      described_class::TranscriptionResult.new(text: {
        transcript_items: [{ speaker: 'operator', start_sec: 2, text: 'Добрый день' },
                           { speaker: 'client', start_sec: 7, text: 'Нужна запись' }],
        summary: 'Пациент попросил запись.', outcome: 'booked', topics: ['запись']
      }.to_json)
    )

    described_class.new(call_session).perform

    recording = call_session.reload.metadata['recording']
    expect(recording['audio_probe']).to include('channels' => 2, 'channel_layout' => 'stereo')
    expect(recording['transcription']).to include('summary' => 'Пациент попросил запись.', 'outcome' => 'booked', 'channels' => 2)
    expect(recording.dig('transcription', 'text')).to eq("[00:02] Сотрудник: Добрый день\n[00:07] Клиент: Нужна запись")
    expect(voice_message.reload.content_attributes['data']).to include(
      'transcript_summary' => 'Пациент попросил запись.', 'transcript_outcome' => 'booked', 'transcript_topics' => ['запись']
    )
  end

  describe 'atomic call metering' do
    let(:metering) { Accounts::MonthlyAiUsageService.new(account) }

    before do
      allow(Telephony::CallTranscript).to receive(:probe).and_return('channels' => 1, 'duration_seconds' => 31)
      allow(Accounts::MonthlyAiUsageService).to receive(:new).with(account).and_return(metering)
    end

    it 'rolls back transcript, billed_at and usage if a fault occurs after the counter write' do
      allow(metering).to receive(:record_call_analysis!).and_wrap_original do |original, **args|
        original.call(**args)
        raise ActiveRecord::StatementInvalid, 'injected after usage write'
      end
      expect { described_class.new(call_session).perform }.to raise_error(ActiveRecord::StatementInvalid)
      expect([call_session.reload.transcript_ref, call_session.metadata.dig('recording', 'transcription')]).to eq([nil, nil])
      expect(Accounts::AiUsageEvent.count).to eq(0)
      expect(metering.class.new(account.reload).call_analysis_seconds_consumed).to eq(0)

      allow(metering).to receive(:record_call_analysis!).and_call_original
      described_class.new(call_session).perform
      described_class.new(call_session, force: true).perform
      expect(metering.class.new(account.reload).call_analysis_seconds_consumed).to eq(31)
      expect(Accounts::AiUsageEvent.count).to eq(1)
      expect(call_session.reload.metadata.dig('recording', 'transcription', 'billed_at')).to be_present
    end

    it 'keeps historical billed calls free on forced retranscription after the additive migration' do
      metadata = call_session.metadata.deep_dup
      metadata['recording']['transcription'] = { 'billed_at' => 1.day.ago.iso8601 }
      call_session.update!(metadata: metadata)
      described_class.new(call_session, force: true).perform
      expect(Accounts::AiUsageEvent.count).to eq(0)
      expect(metering.class.new(account.reload).call_analysis_seconds_consumed).to eq(0)
    end
  end

  it 'does not transcribe when workspace call transcription is disabled' do
    account.update!(call_transcriptions: false)

    expect(described_class.new(call_session).perform).to eq(error: 'Transcription not available')
    expect(Llm::Runtime).not_to have_received(:transcribe)
  end

  it 'persists a completed transcription status from the canonical AI voice runtime transcript without another LLM call' do
    call_session.update!(
      metadata: call_session.metadata.deep_merge(
        'recording' => { 'transcription' => { 'status' => 'queued' } },
        'ai_voice' => {
          'transcript' => {
            'final_items' => [
              { 'speaker' => 'caller', 'text' => 'Подскажите статус заказа' },
              { 'speaker' => 'assistant', 'text' => 'Сейчас проверю' }
            ]
          }
        }
      )
    )

    result = described_class.new(call_session).perform

    expect(result).to include(success: true, transcript: "Клиент: Подскажите статус заказа\nСотрудник: Сейчас проверю")
    expect(Llm::Runtime).not_to have_received(:transcribe)
    expect(call_session.reload.metadata.dig('recording', 'transcription')).to include(
      'status' => 'completed',
      'source' => 'ai_voice_runtime'
    )
  end

  it 'does not attach a recording transcript to a newer unsourced legacy voice_call when exact bubble exists' do
    legacy_voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      content_type: :voice_call,
      content_attributes: { 'data' => { 'status' => 'completed' } }
    )

    described_class.new(call_session).perform

    expect(voice_message.reload.content_attributes.dig('data', 'transcript_ref')).to eq('call_recording_transcript:operator-call-1')
    expect(legacy_voice_message.reload.content_attributes.dig('data', 'transcript_ref')).to be_blank
    expect(legacy_voice_message.content_attributes.dig('data', 'transcript')).to be_blank
  end

  it 'rejects recording storage keys that resolve through symlinks outside storage' do
    outside_path = Rails.root.join('tmp/operator-call-secret.wav')
    FileUtils.rm_f(recording_path)
    File.binwrite(outside_path, "RIFF\x24\x00\x00\x00WAVEfmt ")
    FileUtils.ln_s(outside_path, recording_path)

    expect { described_class.new(call_session).perform }.to raise_error(described_class::RecordingNotFound)
    expect(Llm::Runtime).not_to have_received(:transcribe)
  ensure
    FileUtils.rm_f(outside_path) if defined?(outside_path) && outside_path.present?
  end

  it 'uses the native OpenRouter transcription endpoint for dedicated STT models' do
    service = described_class.new(call_session)
    allow(service).to receive(:model).and_return('openai/gpt-4o-mini-transcribe')
    allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-4o-mini-transcribe', account: account).and_return('openrouter')
    allow(Llm::Models).to receive(:type_for).with('openai/gpt-4o-mini-transcribe', account: account).and_return('transcription')
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('openrouter-key')
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.ai/api/v1')

    expect(Llm::Runtime).to receive(:transcribe).with(
      feature: :audio_transcription,
      account: account,
      model: 'openai/gpt-4o-mini-transcribe',
      input: recording_path.to_s,
      observability: hash_including(runtime_mode: 'call_recording_transcription'),
      options: { temperature: 0.2 }
    ).and_return(response)

    expect(service.perform).to include(success: true, transcript: transcript)
  end

  it 'does not send a language or example prompt for dual-channel recordings' do
    call_session.update!(
      metadata: call_session.metadata.deep_merge(
        'recording' => {
          'layout' => 'dual_channel',
          'channels' => 2,
          'channel_layout' => 'stereo',
          'channel_map' => {
            'channel_1' => 'user_audio',
            'channel_2' => 'peer_audio'
          }
        }
      )
    )

    expect(Llm::Runtime).to receive(:transcribe).with(hash_including(options: { temperature: 0.2 })).and_return(response)

    expect(described_class.new(call_session).perform).to include(success: true, transcript: transcript)
  end

  it 'uses inspected stereo channels and an explicit channel map for attribution' do
    call_session.update!(metadata: call_session.metadata.deep_merge(
      'recording' => { 'channel_map' => { 'FL' => 'client', 'FR' => 'operator' } }
    ))
    service = described_class.new(call_session)
    service.instance_variable_set(:@audio_probe, { 'channels' => 2 })

    expect(service.send(:speaker_channel_prompt)).to include(
      'Channel 1 (Left channel) is Client', 'Channel 2 (Right channel) is Operator'
    )
  end

  it 'stages and transcribes a recording from remote S3 storage when not cached on local disk' do
    FileUtils.rm_f(recording_path)
    allow(Storage::VoiceRecordingRemoteStorage).to receive(:download)
      .with('voice-recordings/1/operator-call-1/recording.wav')
      .and_return("RIFF\x24\x00\x00\x00WAVEfmt ")

    result = described_class.new(call_session).perform

    expect(result).to include(success: true, transcript: transcript)
    expect(Storage::VoiceRecordingRemoteStorage).to have_received(:download)
      .with('voice-recordings/1/operator-call-1/recording.wav')
  end

  it 'uses OpenRouter chat with minimal reasoning, clinic doctors and IVR pre-roll stripping for Gemini 3.8 Flash' do
    create(:scheduling_resource, account: account, name: 'Куатова Алия Даулетбековна')
    service = described_class.new(call_session)
    allow(service).to receive(:model).and_return('google/gemini-3.8-flash')
    allow(Llm::Config).to receive(:provider_for_model).with('google/gemini-3.8-flash', account: account).and_return('openrouter')
    allow(Llm::Models).to receive(:type_for).with('google/gemini-3.8-flash', account: account).and_return('chat')
    allow(Llm::Models).to receive(:supports_audio_input?).with('google/gemini-3.8-flash', account: account).and_return(true)

    payload = '{"summary":"Запись к врачу.","outcome":"booked","topics":["УЗИ"],' \
              '"items":[[1,"op","Добрый день"],[4,"cl","Здравствуйте"]]}'
    chat_response = instance_double(RubyLLM::Message, content: payload)
    expect(Llm::Runtime).to receive(:chat) do |args|
      prompt_text = args[:messages].first[:content].text
      expect(prompt_text).to include('Куатова Алия Даулетбековна', 'Сервисті жақсарту үшін жазамыз')
      expect(args[:options]).to eq(temperature: 0.1, params: { reasoning: { effort: 'minimal' } })
      chat_response
    end

    result = service.perform
    expect(result).to include(success: true, transcript: "[00:01] Сотрудник: Добрый день\n[00:04] Клиент: Здравствуйте")
    expect(call_session.reload.metadata.dig('recording', 'transcription', 'model')).to eq('google/gemini-3.8-flash')
  end

  it 'persists summary and clears stale transcript text when a forced re-transcription finds only IVR pre-roll' do
    call_session.update!(
      metadata: call_session.metadata.deep_merge(
        'recording' => {
          'transcription' => {
            'status' => 'completed',
            'text' => '[00:00] Сотрудник: Сервис тажахсартуишен жазамас.',
            'transcript_items' => [{ 'speaker' => 'operator', 'start_sec' => 0, 'text' => 'Сервис тажахсартуишен жазамас.' }]
          }
        }
      )
    )
    service = described_class.new(call_session, force: true)
    allow(service).to receive(:model).and_return('google/gemini-3.8-flash')
    allow(Llm::Config).to receive(:provider_for_model).with('google/gemini-3.8-flash', account: account).and_return('openrouter')
    allow(Llm::Models).to receive(:type_for).with('google/gemini-3.8-flash', account: account).and_return('chat')
    allow(Llm::Models).to receive(:supports_audio_input?).with('google/gemini-3.8-flash', account: account).and_return(true)

    payload = '{"summary":"Звонок прервался на приветствии автоответчика оператора связи, разговора не было.",' \
              '"outcome":"no_answer","topics":[],"items":[]}'
    allow(Llm::Runtime).to receive(:chat).and_return(instance_double(RubyLLM::Message, content: payload))

    result = service.perform
    expect(result).to include(
      success: true,
      transcript: 'Звонок прервался на приветствии автоответчика оператора связи, разговора не было.'
    )
    tr = call_session.reload.metadata.dig('recording', 'transcription')
    expect(tr).to include(
      'status' => 'completed',
      'model' => 'google/gemini-3.8-flash',
      'outcome' => 'no_answer',
      'text' => '',
      'transcript_items' => []
    )
  end

  describe 'selected DEV VoiceCore provider' do
    let(:adapter) { instance_double(Telephony::VoiceCoreRecordingTranscription) }
    let(:local_result) do
      { 'text' => '[00:00] Говорящий: Тест',
        'transcript_items' => [{ 'speaker' => 'unknown', 'channel' => 0, 'start_sec' => 0.2, 'end_sec' => 1.1, 'text' => 'Тест' }],
        'summary' => '', 'outcome' => '', 'topics' => [],
        'provider' => 'voicecore', 'model' => Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256,
        'voicecore' => { 'channel_status' => 'mono', 'model_version' => Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256 },
        'audio_probe' => { 'channels' => 1, 'duration_seconds' => 31 } }
    end

    before do
      allow(Telephony::VoiceCoreClient).to receive(:selected_for?).with(account).and_return(true)
      allow(Telephony::VoiceCoreRecordingTranscription).to receive(:new).with(call_session).and_return(adapter)
      allow(adapter).to receive(:perform) { local_result.deep_dup }
      allow(Llm::Runtime).to receive(:chat)
      allow(Telephony::CallTranscript).to receive(:probe)
      allow(Telephony::CallTranscript).to receive(:channel_activity)
    end

    it 'uses native storage/message without cloud normalization, probes or enrichment' do
      described_class.new(call_session).perform
      expect(Llm::Runtime).not_to have_received(:transcribe)
      expect(Llm::Runtime).not_to have_received(:chat)
      expect(Telephony::CallTranscript).not_to have_received(:probe)
      expect(Telephony::CallTranscript).not_to have_received(:channel_activity)
      metadata = call_session.reload.metadata.dig('recording', 'transcription')
      expect(metadata).to include('provider' => 'voicecore', 'model' => Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256,
                                  'source' => 'audio_transcription')
      expect(metadata['transcript_items'].first).to include('speaker' => 'unknown', 'channel' => 0, 'start_sec' => 0.2, 'end_sec' => 1.1)
      expect(voice_message.reload.content_attributes.dig('data', 'transcript_items')).to eq(metadata['transcript_items'])
    end

    it 'preserves native cache, force and one-time call metering' do
      described_class.new(call_session).perform
      described_class.new(call_session).perform
      described_class.new(call_session, force: true).perform
      expect(Accounts::AiUsageEvent.count).to eq(1)
      expect(Accounts::MonthlyAiUsageService.new(account.reload).call_analysis_seconds_consumed).to eq(31)
      expect(adapter).to have_received(:perform).twice
    end

    it 'returns a fixed local error without inference fallback or usage on failure' do
      allow(adapter).to receive(:perform).and_raise(Telephony::VoiceCoreClient::Error.new('invalid_response'))
      result = described_class.new(call_session).perform
      expect(result).to eq(error: 'VoiceCore transcription unavailable', error_code: 'invalid_response', retryable: false)
      expect(Llm::Runtime).not_to have_received(:transcribe)
      expect(Llm::Runtime).not_to have_received(:chat)
      expect(Accounts::AiUsageEvent.count).to eq(0)
      expect(call_session.reload.metadata.dig('recording', 'transcription')).to be_nil
    end

    it 'does not persist or meter an unapproved manifest and never switches to paid inference' do
      allow(adapter).to receive(:perform).and_raise(Telephony::VoiceCoreClient::Error.new('unapproved_manifest'))
      expect(described_class.new(call_session).perform).to include(error_code: 'unapproved_manifest', retryable: false)
      expect(call_session.reload.metadata.dig('recording', 'transcription')).to be_nil
      expect(Accounts::AiUsageEvent.count).to eq(0)
      expect(Llm::Runtime).not_to have_received(:transcribe)
      expect(Llm::Runtime).not_to have_received(:chat)
    end

    it 'keeps the native account flag and quota before local inference' do
      account.update!(call_transcriptions: false)
      expect(described_class.new(call_session).perform).to eq(error: 'Transcription not available')
      account.update!(call_transcriptions: true)
      allow(account).to receive(:call_analysis_quota_available?).and_return(false)
      expect(described_class.new(call_session).perform).to eq(error: 'Transcription not available')
      expect(adapter).not_to have_received(:perform)
    end
  end
end
