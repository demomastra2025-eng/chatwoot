# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::UiActionContract do
  describe '.normalize' do
    it 'keeps only typed whitelisted bounded UI actions' do
      actions = described_class.normalize(
        [
          { 'type' => 'open_contact', 'label' => '<b>Open contact</b>', 'target_id' => 42, 'extra' => 'ignored' },
          { 'type' => 'click_dom', 'label' => 'Delete everything', 'target_id' => '#danger' },
          { 'type' => 'open_tasks', 'label' => 'Tasks' },
          { 'type' => 'open_deal', 'label' => 'Deal', 'target_id' => '9' },
          { 'type' => 'open_company', 'label' => 'Company', 'target_id' => '8' },
          { 'type' => 'open_captain_observability', 'label' => 'Observability', 'target_id' => '' },
          { 'type' => 'open_reports', 'label' => 'Reports', 'target_id' => '' }
        ]
      )

      expect(actions).to eq(
        [
          { 'type' => 'open_contact', 'label' => 'Open contact', 'target_id' => '42' },
          { 'type' => 'open_tasks', 'label' => 'Tasks', 'target_id' => '' },
          { 'type' => 'open_deal', 'label' => 'Deal', 'target_id' => '9' },
          { 'type' => 'open_company', 'label' => 'Company', 'target_id' => '8' },
          { 'type' => 'open_captain_observability', 'label' => 'Observability', 'target_id' => '' }
        ]
      )
    end

    it 'returns an empty array for invalid payload shapes' do
      expect(described_class.normalize('open_contact')).to eq([])
      expect(described_class.normalize([{ 'type' => 'open_contact', 'label' => '', 'target_id' => '42' }])).to eq([])
    end

    it 'rejects target-specific actions without a target id but allows create actions without one' do
      expect(
        described_class.normalize(
          [
            { 'type' => 'open_deal', 'label' => 'Open deal', 'target_id' => '' },
            { 'type' => 'create_deal', 'label' => 'Create deal' }
          ]
        )
      ).to eq([{ 'type' => 'create_deal', 'label' => 'Create deal', 'target_id' => '' }])
    end

    it 'stops scanning after bounded accepted and raw input action counts' do
      exploding_label = Object.new.tap do |object|
        def object.to_s
          raise 'should not normalize actions beyond the accepted limit'
        end
      end
      valid_actions = Array.new(5) do |index|
        { 'type' => 'open_contact', 'label' => "Open #{index}", 'target_id' => index.to_s }
      end

      expect(
        described_class.normalize(valid_actions + [{ 'type' => 'open_contact', 'label' => exploding_label, 'target_id' => 'boom' }]).length
      ).to eq(5)

      unaccepted_actions = Array.new(described_class::MAX_INPUT_ACTIONS) do
        { 'type' => 'click_dom', 'label' => 'Unsafe', 'target_id' => '#danger' }
      end

      expect(
        described_class.normalize(unaccepted_actions + [{ 'type' => 'open_contact', 'label' => exploding_label, 'target_id' => 'boom' }])
      ).to eq([])
    end
  end
end
