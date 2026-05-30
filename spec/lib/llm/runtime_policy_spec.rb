# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::RuntimePolicy do
  let(:account) { create(:account) }

  describe '.thinking_options' do
    it 'returns nil when thinking is disabled' do
      expect(
        described_class.thinking_options(feature: :assistant, account: account, model: 'gpt-5.1')
      ).to be_nil
    end

    it 'returns effort for supported models' do
      account.update!(captain_runtime: { 'assistant_thinking_effort' => 'high' })

      expect(
        described_class.thinking_options(feature: :assistant, account: account, model: 'gpt-5.1')
      ).to eq(effort: 'high')
    end

    it 'adds a budget for anthropic models' do
      account.update!(captain_runtime: { 'assistant_thinking_effort' => 'medium' })

      expect(
        described_class.thinking_options(feature: :assistant, account: account, model: 'claude-sonnet-4.5')
      ).to eq(effort: 'medium', budget: 4096)
    end
  end

  describe '.moderation_enabled?' do
    it 'defaults runtime assistant and copilot moderation to disabled' do
      expect(described_class.moderation_enabled?(feature: :assistant, account: account)).to be false
      expect(described_class.moderation_enabled?(feature: :copilot, account: account)).to be false
    end

    it 'reads moderation flags from runtime preferences' do
      account.update!(captain_runtime: { 'assistant_moderation' => true, 'copilot_moderation' => true })

      expect(described_class.moderation_enabled?(feature: :copilot, account: account)).to be true
      expect(described_class.moderation_enabled?(feature: :assistant, account: account)).to be true
    end

    it 'defaults non-runtime features to disabled until a service opts in explicitly' do
      expect(described_class.moderation_enabled?(feature: :editor, account: account)).to be false
    end

    it 'supports explicit moderation overrides for non-runtime features' do
      expect(
        described_class.moderation_enabled?(feature: :editor, preferences: { 'editor_moderation' => true })
      ).to be true
    end
  end

  describe '.moderation_failure_mode' do
    it 'defaults to fail_open' do
      expect(described_class.moderation_failure_mode(feature: :assistant, account: account)).to eq('fail_open')
      expect(described_class.fail_closed_moderation?(feature: :assistant, account: account)).to be(false)
    end

    it 'reads the global moderation failure mode from runtime preferences' do
      account.update!(captain_runtime: { 'moderation_failure_mode' => 'fail_closed' })

      expect(described_class.moderation_failure_mode(feature: :assistant, account: account)).to eq('fail_closed')
      expect(described_class.fail_closed_moderation?(feature: :assistant, account: account)).to be(true)
    end
  end

  describe '.safety_blocklist' do
    it 'merges global and feature-specific safety blocklists' do
      account.update!(
        captain_runtime: {
          'safety_blocklist' => ['global ban'],
          'assistant_safety_blocklist' => ['assistant ban'],
          'copilot_safety_blocklist' => ['copilot ban']
        }
      )

      expect(described_class.safety_blocklist(feature: :assistant, account: account)).to contain_exactly(
        'global ban',
        'assistant ban'
      )
      expect(described_class.safety_blocklist(feature: :copilot, account: account)).to contain_exactly(
        'global ban',
        'copilot ban'
      )
    end
  end

  describe '.release_gate_config' do
    it 'returns normalized release gate configuration from runtime preferences' do
      preferences = {
        'release_gate' => {
          'enabled' => false,
          'min_request_count' => '25',
          'max_error_rate' => '0.1',
          'max_schema_invalid_rate' => 0.03,
          'max_avg_duration_ms' => '12000'
        }
      }

      expect(described_class.release_gate_config(preferences: preferences)).to include(
        enabled: false,
        min_request_count: 25,
        max_error_rate: 0.1,
        max_schema_invalid_rate: 0.03,
        max_avg_duration_ms: 12_000
      )
    end
  end

  describe '.trace_input_capture?' do
    it 'disables trace capture for sensitive privacy profiles even outside production' do
      expect(
        described_class.trace_input_capture?(preferences: { 'privacy_profile' => 'sensitive', 'trace_input_capture' => true })
      ).to be(false)
      expect(
        described_class.trace_output_capture?(preferences: { 'privacy_profile' => 'zdr_required', 'trace_output_capture' => true })
      ).to be(false)
    end

    it 'keeps account privacy profile when partial trace preferences are supplied' do
      account.update!(captain_runtime: { 'privacy_profile' => 'sensitive' })

      expect(
        described_class.trace_input_capture?(account: account, preferences: { 'trace_input_capture' => true })
      ).to be(false)
    end
  end

  describe '.agent_high_risk_tool_allowed?' do
    it 'allows only explicitly listed high-risk tool ids by default' do
      account.update!(
        captain_runtime: {
          'agent_high_risk_tool_ids' => ['create_deal']
        }
      )

      expect(described_class.agent_high_risk_tool_allowed?('create_deal', account: account)).to be(true)
      expect(described_class.agent_high_risk_tool_allowed?('cancel_appointment', account: account)).to be(false)
    end

    it 'allows all high-risk tools when the global autonomous mode is enabled' do
      account.update!(captain_runtime: { 'agent_high_risk_tools' => 'enabled' })

      expect(described_class.agent_high_risk_tool_allowed?('cancel_appointment', account: account)).to be(true)
    end
  end
end
