require 'rails_helper'

RSpec.describe Llm::TranscriptionTimings do
  it 'logs monotonic stage durations and pre-HTTP elapsed time without account or audio identifiers' do
    entries = []
    allow(Rails.logger).to receive(:info) { |entry| entries << entry }

    timings = described_class.new(source: 'message')
    expect(timings.measure(:model_selection) { 'openai/gpt-4o-transcribe' }).to eq('openai/gpt-4o-transcribe')
    timings.mark(:provider_http_start)
    expect { timings.measure(:provider_request) { raise 'provider unavailable' } }.to raise_error('provider unavailable')

    expect(entries.map { |entry| entry[/stage=(\w+)/, 1] }).to eq(%w[model_selection provider_http_start provider_request])
    expect(entries).to all(match(/duration_ms=\d+(?:\.\d+)? elapsed_ms=\d+(?:\.\d+)?/))
    expect(entries.last).to include('status=error')
    expect(entries.join).not_to match(/account_id|file_name|api_key|audio_data/)
  end
end
