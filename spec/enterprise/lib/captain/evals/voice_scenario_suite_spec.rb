# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::VoiceScenarioSuite do
  it 'passes default voice scenarios for interruption, latency, and transcript fallback' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.voice_scenarios',
      total_count: 2,
      passed_count: 2,
      failed_count: 0,
      status: 'pass'
    )
    expect(result.cases).to include(
      include(id: 'voice.interruption_stops_audio', status: 'pass'),
      include(id: 'voice.transcript_fallback_for_audio_judge', status: 'pass')
    )
  end

  it 'fails when audio continues after caller interruption' do
    Tempfile.create(['voice_scenarios_bad', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: voice.bad_interruption
              description: Audio must stop after interruption.
              tags: [ai_voice, interruption]
              events:
                - action: caller_interrupt
                  role: caller
                  interrupted: true
                - action: realtime_audio_out
                  role: assistant
                  stopped: false
              expected:
                require_interruption_stop: true
        YAML
      )
      file.rewind

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(total_count: 1, failed_count: 1, status: 'fail')
      expect(result.cases.first[:failures]).to include('voice interruption was not respected')
    end
  end

  it 'fails when an interruption stop is required but no interruption event is present' do
    Tempfile.create(['voice_scenarios_missing_interrupt', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: voice.missing_interruption
              description: Interruption assertions require an interruption event.
              tags: [ai_voice, interruption]
              events:
                - action: caller_transcript_final
                  role: caller
                  transcript: "Можно перебью?"
                - action: ai_transcript_turn
                  role: assistant
                  transcript: "Слушаю."
              expected:
                require_interruption_stop: true
        YAML
      )
      file.rewind

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(total_count: 1, failed_count: 1, status: 'fail')
      expect(result.cases.first[:failures]).to include('voice interruption event missing')
    end
  end

  it 'fails latency budgets when required latency signals are missing' do
    Tempfile.create(['voice_scenarios_missing_latency', '.yml']) do |file|
      file.write(
        <<~YAML
          cases:
            - id: voice.missing_ttfb
              description: TTFB budget requires TTFB events.
              tags: [ai_voice, latency]
              events:
                - action: caller_transcript_final
                  role: caller
                  transcript: "Алло"
                - action: ai_transcript_turn
                  role: assistant
                  transcript: "Здравствуйте"
              expected:
                max_ttfb_ms: 1200
        YAML
      )
      file.rewind

      result = described_class.new(cases_path: file.path).call

      expect(result.to_h).to include(total_count: 1, failed_count: 1, status: 'fail')
      expect(result.cases.first[:failures]).to include('TTFB missing')
    end
  end
end
