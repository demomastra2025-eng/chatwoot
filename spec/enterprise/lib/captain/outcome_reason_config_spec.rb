require 'rails_helper'

RSpec.describe Captain::OutcomeReasonConfig do
  describe '.normalize_settings' do
    it 'moves a saved "other" reason from the middle of the list to the end and keeps it active' do
      settings = described_class.normalize_settings(
        'handoff_reasons' => [
          { 'id' => 'billing', 'label' => 'Billing', 'active' => true },
          { 'id' => 'other', 'label' => 'Other', 'active' => false },
          { 'id' => 'technical', 'label' => 'Technical', 'active' => false }
        ]
      )

      expect(settings['handoff_reasons']).to eq(
        [
          { 'id' => 'billing', 'label' => 'Billing', 'active' => true },
          { 'id' => 'technical', 'label' => 'Technical', 'active' => false },
          { 'id' => 'other', 'label' => 'Other', 'active' => true }
        ]
      )
    end

    it 'keeps the limit of reasons when "other" is moved out of the middle of a full list' do
      reason = ->(index) { { 'id' => "reason_#{index}", 'label' => "Reason #{index}" } }
      reasons = (1..5).map(&reason) + [{ 'id' => 'other', 'label' => 'Other' }] + (6..19).map(&reason)

      completion = described_class.normalize_settings('completion_reasons' => reasons)['completion_reasons']

      expect(completion.size).to eq(described_class::MAX_REASONS_PER_TYPE)
      expect(completion.first['id']).to eq('reason_1')
      expect(completion.last['id']).to eq('other')
    end

    it 'appends the default "other" reason when the list has none' do
      settings = described_class.normalize_settings('handoff_reasons' => [{ 'id' => 'billing', 'label' => 'Billing' }])

      expect(settings['handoff_reasons'].pluck('id')).to eq(%w[billing other])
      expect(settings['handoff_reasons'].last).to include('label' => 'Other', 'active' => true)
    end
  end

  describe '#prompt_context' do
    it 'lists "other" last for old saved data that has it in the middle of the list' do
      assistant = create(:captain_assistant, account: create(:account))
      assistant.update!(
        config: assistant.config.to_h.deep_merge(
          'outcome_reason_settings' => {
            'handoff_reasons' => [
              { 'id' => 'billing', 'label' => 'Billing', 'active' => true },
              { 'id' => 'other', 'label' => 'Other', 'active' => true },
              { 'id' => 'technical', 'label' => 'Technical', 'active' => true }
            ]
          }
        )
      )

      context = described_class.new(assistant).prompt_context

      expect(context['handoff'].pluck('id')).to eq(%w[billing technical other])
    end
  end
end
