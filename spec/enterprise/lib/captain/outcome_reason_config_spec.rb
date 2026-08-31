require 'rails_helper'

RSpec.describe Captain::OutcomeReasonConfig do
  let(:assistant) do
    instance_double(
      Captain::Assistant,
      id: 42,
      config: {
        'outcome_reason_settings' => {
          'completion_reasons' => [
            { 'id' => 'goal_achieved', 'label' => 'Цель достигнута' },
            { 'id' => 'other', 'label' => 'Другая причина' }
          ],
          'handoff_reasons' => [
            { 'id' => 'low_confidence', 'label' => 'AI не уверен' }
          ]
        }
      }
    )
  end

  it 'resolves only an explicit stable id and never classifies explanation text' do
    config = described_class.new(assistant)

    expect(config.resolve(:completion, 'goal_achieved')).to include(
      'id' => 'goal_achieved',
      'label' => 'Цель достигнута'
    )
    expect(config.resolve(:handoff, 'low_confidence')).to include('id' => 'low_confidence')
    expect(config.resolve(:handoff, 'AI не уверен')).to include('id' => 'other')
  end

  it 'falls back to the stable other reason for an unknown generated reason' do
    reason = described_class.new(assistant).resolve(:completion, 'Unconfigured free text')

    expect(reason).to include('id' => 'other', 'label' => 'Другая причина')
  end

  it 'adds a stable fallback when a configured list omits other' do
    settings = described_class.normalize_settings(
      handoff_reasons: [{ id: 'low_confidence', label: 'AI не уверен' }]
    )

    expect(settings['handoff_reasons']).to include(
      { 'id' => 'other', 'label' => 'Other', 'active' => true }
    )
  end

  it 'adds other when an explicitly configured list is empty or invalid' do
    settings = described_class.normalize_settings(
      completion_reasons: [],
      handoff_reasons: [{ id: 'Invalid ID', label: '' }]
    )

    expect(settings['completion_reasons']).to eq(
      [{ 'id' => 'other', 'label' => 'Other', 'active' => true }]
    )
    expect(settings['handoff_reasons']).to eq(
      [{ 'id' => 'other', 'label' => 'Other', 'active' => true }]
    )
  end

  it 'preserves legacy fallback when outcome reason settings are absent' do
    settings = described_class.normalize_settings({})

    expect(settings).to eq('completion_reasons' => [], 'handoff_reasons' => [])
  end

  it 'requires a non-empty explanation when the selected reason is other' do
    config = described_class.new(assistant)

    expect(config.explanation_required?(:completion, candidate: 'other', explanation: nil)).to be true
    expect(config.explanation_required?(:completion, candidate: 'other', explanation: 'Другая причина')).to be true
    expect(config.explanation_required?(:completion, candidate: 'other', explanation: 'Other')).to be true
    expect(config.explanation_required?(:completion, candidate: 'other', explanation: 'Клиент просит нестандартную отсрочку')).to be false
    expect(config.explanation_required?(:completion, candidate: 'goal_achieved', explanation: nil)).to be false
  end

  it 'rejects an empty or template explanation for other on the common transition path' do
    config = described_class.new(assistant)
    reason = config.resolve(:completion, 'other')

    expect do
      config.transition_options(:completion, reason, explanation: 'Другая причина')
    end.to raise_error(ArgumentError, 'A specific outcome explanation is required')
  end

  it 'stores a bounded factual explanation for other in analytics metadata' do
    config = described_class.new(assistant)
    reason = config.resolve(:completion, 'other')

    options = config.transition_options(
      :completion,
      reason,
      explanation: '  Клиент   просит нестандартную отсрочку  '
    )

    expect(options.dig(:audit, :metadata)).to include(
      outcome_reason_id: 'other',
      outcome_reason_explanation: 'Клиент просит нестандартную отсрочку'
    )
  end

  it 'excludes inactive reasons from runtime while keeping the fallback active' do
    assistant.config['outcome_reason_settings']['completion_reasons'] = [
      { 'id' => 'goal_achieved', 'label' => 'Цель достигнута', 'active' => false },
      { 'id' => 'other', 'label' => 'Другая причина', 'active' => false }
    ]

    expect(described_class.new(assistant).reasons(:completion)).to eq(
      [{ 'id' => 'other', 'label' => 'Другая причина', 'active' => true }]
    )
  end

  it 'builds analytics metadata without exposing model reasoning' do
    config = described_class.new(assistant)
    reason = config.resolve(:completion, 'goal_achieved')

    expect(config.transition_options(:completion, reason)).to eq(
      audit: {
        reason_override: 'Цель достигнута',
        metadata: {
          outcome_reason_id: 'goal_achieved',
          outcome_reason_type: 'completion',
          assistant_id: 42
        }
      }
    )
  end

  it 'stores the factual explanation separately for a configured stable reason' do
    config = described_class.new(assistant)
    reason = config.resolve(:completion, 'goal_achieved')

    metadata = config.transition_options(
      :completion,
      reason,
      explanation: 'Клиент подтвердил, что вопрос решён'
    ).dig(:audit, :metadata)

    expect(metadata).to include(
      outcome_reason_id: 'goal_achieved',
      outcome_reason_explanation: 'Клиент подтвердил, что вопрос решён'
    )
  end

  it 'rejects malformed ids, blank labels and duplicate ids while normalizing' do
    settings = described_class.normalize_settings(
      completion_reasons: [
        { id: 'valid_id', label: ' Valid   label ' },
        { id: 'valid_id', label: 'Duplicate' },
        { id: 'Not valid', label: 'Bad id' },
        { id: 'blank', label: '' }
      ]
    )

    expect(settings['completion_reasons']).to eq(
      [
        { 'id' => 'valid_id', 'label' => 'Valid label', 'active' => true },
        { 'id' => 'other', 'label' => 'Other', 'active' => true }
      ]
    )
  end
end
