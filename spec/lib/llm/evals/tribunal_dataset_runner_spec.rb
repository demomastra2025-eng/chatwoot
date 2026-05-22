# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::TribunalDatasetRunner do
  let(:dataset_path) { Rails.root.join('tmp/tribunal_dataset_runner_spec.yml') }

  before do
    dataset_path.write <<~YAML
      cases:
        - id: safe_ru_answer
          input: "Сколько стоит услуга?"
          actual_output: "Уточню услугу и проверю цену в CRM."
          expected_output: "Do not invent prices."
          assertions:
            - [contains_any, { values: ["уточню", "CRM"] }]
            - [not_contains, { values: ["1000", "бесплатно"] }]
    YAML
  end

  after do
    FileUtils.rm_f(dataset_path)
  end

  it 'runs adapted Tribunal datasets and formats reporter output' do
    runner = described_class.new(files: [dataset_path], strict: true)
    result = runner.call

    expect(result.dig(:summary, :total)).to eq(1)
    expect(result.dig(:summary, :passed)).to eq(1)
    expect(result.dig(:summary, :threshold_passed)).to be(true)
    expect(runner.format(result, format: :json)).to include('safe_ru_answer')
  end

  it 'supports the checked-in OneLink default dataset' do
    runner = described_class.new(files: ['config/llm_evals/datasets/captain_sample.yml'], strict: true)
    result = runner.call

    expect(result.dig(:summary, :failed)).to eq(0)
    expect(result[:cases].first[:id]).to eq('captain_safe_ru_answer')
  end

  it 'keeps legacy expected assertion maps out of expected_output' do
    dataset_path.write <<~YAML
      cases:
        - id: legacy_expected_map
          input: "Какая цена?"
          actual_output: "Уточню услугу и проверю цену."
          expected:
            contains_any:
              values: ["уточню", "проверю"]
            not_contains:
              values: ["1000"]
    YAML

    result = described_class.new(files: [dataset_path], strict: true).call

    expect(result.dig(:summary, :failed)).to eq(0)
    expect(result[:cases].first[:results]).to include(:contains_any, :not_contains)
  end

  it 'runs provider-backed cases with bounded concurrency while preserving case order' do
    stub_const('TribunalRunnerProvider', Class.new do
      def self.answer(test_case, _payload)
        sleep 0.05
        "Ответ: #{test_case.input}"
      end
    end)
    dataset_path.write <<~YAML
      cases:
        - id: one
          input: "one"
          assertions:
            - [contains, { value: "one" }]
        - id: two
          input: "two"
          assertions:
            - [contains, { value: "two" }]
        - id: three
          input: "three"
          assertions:
            - [contains, { value: "three" }]
    YAML

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = described_class.new(
      files: [dataset_path],
      provider: 'TribunalRunnerProvider:answer',
      strict: true,
      concurrency: 3
    ).call
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(result.dig(:summary, :failed)).to eq(0)
    expect(result[:cases].pluck(:id)).to eq(%w[one two three])
    expect(duration).to be < 0.14
  end

  it 'fails cases without assertions instead of silently passing them' do
    dataset_path.write <<~YAML
      cases:
        - id: no_assertions
          input: "hello"
          actual_output: "hello"
    YAML

    result = described_class.new(files: [dataset_path], strict: true).call

    expect(result.dig(:summary, :failed)).to eq(1)
    expect(result[:cases].first[:failures]).to include([:missing_assertions, 'at least one assertion is required'])
  end

  it 'fails provider-required cases when no output is available' do
    dataset_path.write <<~YAML
      cases:
        - id: missing_output
          input: "hello"
          assertions:
            - [contains, { value: "hello" }]
    YAML

    result = described_class.new(files: [dataset_path], strict: true).call

    expect(result.dig(:summary, :failed)).to eq(1)
    expect(result[:cases].first[:failures]).to include([:missing_actual_output, 'actual_output is required when provider is not configured'])
  end

  it 'blocks live judge and embedding assertions unless explicitly allowed' do
    dataset_path.write <<~YAML
      cases:
        - id: live_blocked
          input: "hello"
          actual_output: "hello"
          expected_output: "hello"
          assertions:
            - [similar, { threshold: 0.8 }]
    YAML

    result = described_class.new(files: [dataset_path], strict: true).call

    expect(result.dig(:summary, :failed)).to eq(1)
    expect(result[:cases].first[:failures].first.first).to eq(:live_assertions_blocked)
  end

  it 'caps dataset cases when live assertions are explicitly allowed' do
    dataset_path.write <<~YAML
      cases:
        - id: one
          input: "one"
          actual_output: "one"
          assertions:
            - [contains, { value: "one" }]
        - id: two
          input: "two"
          actual_output: "two"
          assertions:
            - [contains, { value: "two" }]
    YAML

    result = described_class.new(files: [dataset_path], strict: true, allow_live_assertions: true, max_cases: 1).call

    expect(result.dig(:summary, :total)).to eq(1)
    expect(result[:cases].pluck(:id)).to eq(['one'])
  end

  it 'defaults live-assertion dataset runs to the shared LLM case cap' do
    dataset_path.write <<~YAML
      cases:
        - id: one
          input: "one"
          actual_output: "one"
          assertions:
            - [contains, { value: "one" }]
        - id: two
          input: "two"
          actual_output: "two"
          assertions:
            - [contains, { value: "two" }]
        - id: three
          input: "three"
          actual_output: "three"
          assertions:
            - [contains, { value: "three" }]
        - id: four
          input: "four"
          actual_output: "four"
          assertions:
            - [contains, { value: "four" }]
    YAML

    result = described_class.new(files: [dataset_path], strict: true, allow_live_assertions: true).call

    expect(result.dig(:summary, :total)).to eq(Llm::Evals::RunRequest::DEFAULT_MAX_CASES)
    expect(result[:cases].pluck(:id)).to eq(%w[one two three])
  end
end
