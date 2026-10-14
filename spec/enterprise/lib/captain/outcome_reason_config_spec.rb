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
      reasons = (1..5).map(&reason) + [{ 'id' => 'other', 'label' => 'Other' }] + (6...described_class::MAX_REASONS_PER_TYPE).map(&reason)

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

      context = described_class.new(assistant, source: :assistant).prompt_context

      expect(context['handoff'].pluck('id').last(3)).to eq(%w[billing technical other])
    end
  end

  describe 'platform reasons' do
    let(:assistant) { create(:captain_assistant, account: create(:account, locale: 'ru')) }

    it 'includes the clinic rule closure reason in completion defaults' do
      reasons = described_class.new(assistant).reasons('completion')
      expect(reasons).to include(hash_including('id' => 'closed_against_instructions',
                                                'label' => 'Закрыто не по правилу клиники'))
    end

    it 'reserves room for built-ins while preserving the former maximum of saved custom reasons' do
      custom = (1..30).map { |index| { 'id' => "custom_#{index}", 'label' => "Custom #{index}" } }
      assistant.update!(config: { 'outcome_reason_settings' => { 'handoff_reasons' => custom } })
      reasons = described_class.new(assistant, source: :assistant).normalized_settings['handoff_reasons']
      expect(reasons.size).to eq(described_class::MAX_REASONS_PER_TYPE)
      expect(reasons.map { |reason| reason['id'] }).to include(*described_class::BUILTIN_IDS['handoff'])
      expect(reasons.select { |reason| reason['removable'] }.pluck('id')).to eq((1..20).map { |index| "custom_#{index}" })
    end

    it 'restores standard reasons and translates Other without overwriting custom labels' do
      assistant.update!(config: { 'outcome_reason_settings' => {
                          'handoff_reasons' => [{ 'id' => 'other', 'label' => 'Other' }, { 'id' => 'custom_reason', 'label' => 'Своя причина' }]
                        } })
      reasons = described_class.new(assistant, source: :assistant).normalized_settings['handoff_reasons']
      expect(reasons.find { |reason| reason['id'] == 'other' }).to include('label' => 'Другое', 'locked' => true, 'removable' => false)
      expect(reasons.find { |reason| reason['id'] == 'customer_requested_human' }).to include('removable' => false)
      expect(reasons.find { |reason| reason['id'] == 'custom_reason' }).to include('label' => 'Своя причина', 'removable' => true)
    end

    it 'forces FAQ miss on only when both FAQ and human handoff are available' do
      assistant.update!(
        config: {
          'feature_faq' => false,
          'handoff_enabled' => true,
          'outcome_reason_settings' => {
            'handoff_reasons' => [{ 'id' => 'faq_no_answer', 'label' => 'FAQ', 'active' => false }]
          }
        }
      )
      reason = lambda do
        described_class.new(assistant, source: :assistant).normalized_settings['handoff_reasons'].find { |entry| entry['id'] == 'faq_no_answer' }
      end
      expect(reason.call).to include('active' => true, 'locked' => true, 'removable' => false)
      assistant.update!(config: assistant.config.merge('tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } }))
      expect(reason.call).to include('active' => true, 'locked' => true, 'removable' => false)
    end
  end
end
