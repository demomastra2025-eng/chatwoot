require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::ImageDescriber do
  subject(:describer) { described_class.new(account: account, targets: targets) }

  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation, account: account, content: 'Снимки') }
  let(:attachments) { Array.new(count) { |index| build_image(index) } }
  let(:targets) { attachments.map { |attachment| [attachment, attachment.external_url] } }
  let(:count) { 8 }
  let(:in_flight) { Concurrent::AtomicFixnum.new(0) }
  let(:peak) { Concurrent::AtomicFixnum.new(0) }
  let(:calls) { Concurrent::Array.new }
  let(:call_seconds) { 0.2 }

  def build_image(index, meta: {})
    message.attachments.create!(
      account_id: account.id, file_type: :image, external_url: "https://example.com/#{index}.jpg", meta: meta
    )
  end

  before do
    allow(Captain::ImageRecognitionService).to receive(:new) do |attachment:, **|
      instance_double(Captain::ImageRecognitionService).tap do |recognition|
        allow(recognition).to receive(:perform) do
          calls << attachment.id
          current = in_flight.increment
          peak.update { |value| [value, current].max }
          sleep call_seconds
          in_flight.decrement
          "Описание #{attachment.id}"
        end
      end
    end
  end

  it 'describes every image' do
    expect(describer.perform).to eq(attachments.to_h { |attachment| [attachment.id, "Описание #{attachment.id}"] })
  end

  it 'describes in parallel, five at a time, never one after another' do
    describer
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    describer.perform

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(peak.value).to eq(described_class::MAX_CONCURRENCY)
    # Sequentially 8 calls take 1.6 s; five at a time they take two rounds.
    expect(elapsed).to be < (count * call_seconds * 0.75)
  end

  it 'uses fewer workers than the limit when there are fewer images' do
    stub_const("#{described_class}::MAX_CONCURRENCY", 5)
    two = attachments.first(2)

    described_class.new(account: account, targets: two.map { |attachment| [attachment, attachment.external_url] }).perform

    expect(peak.value).to eq(2)
  end

  context 'with descriptions made before' do
    let(:cached_key) { Captain::ImageRecognitionService::CACHE_KEY }
    let(:attachments) do
      [build_image(0, meta: { cached_key => 'Уже описано' }), build_image(1), build_image(2, meta: { cached_key => '  ' })]
    end

    it 'reuses the cached description and describes only the rest' do
      result = describer.perform

      expect(result[attachments.first.id]).to eq('Уже описано')
      expect(calls).to contain_exactly(attachments[1].id, attachments[2].id)
    end

    it 'does not start a thread when every image is cached' do
      all_cached = Array.new(3) { |index| build_image(10 + index, meta: { cached_key => "Кэш #{index}" }) }
      cached_only = described_class.new(account: account, targets: all_cached.map { |attachment| [attachment, attachment.external_url] })
      allow(cached_only).to receive(:start_workers).and_call_original

      result = cached_only.perform

      expect(result.values).to eq(['Кэш 0', 'Кэш 1', 'Кэш 2'])
      expect(cached_only).not_to have_received(:start_workers)
      expect(calls).to be_empty
    end
  end

  it 'describes an image once, however many times it is listed' do
    doubled = described_class.new(account: account, targets: targets.first(2) * 2)

    doubled.perform

    expect(calls.size).to eq(2)
  end

  it 'returns nothing for nothing' do
    expect(described_class.new(account: account, targets: []).perform).to eq({})
  end

  context 'when the manager cancels while images are being described' do
    let(:call_seconds) { 1.0 }

    it 'stops waiting at once and stops the workers' do
      request_id = 'cancel-during-images'
      describer
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      Captain::ReplySuggestion::RequestStore.request_cancel!(request_id)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect do
        Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: deadline) { describer.perform }
      end.to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect([error.kind, error.stage]).to eq([:cancelled, 'images']) }

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.9
    end

    it 'ends at the deadline of the run' do
      describer
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.3

      expect do
        Captain::ReplySuggestion::RunControl.with(request_id: 'deadline-during-images', deadline: deadline) { describer.perform }
      end.to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect(error.kind).to eq(:deadline) }
    end
  end
end
