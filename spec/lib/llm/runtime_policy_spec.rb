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

  describe '.guardrail_action' do
    it 'defaults prompt injection and sensitive-info guardrails to block' do
      expect(described_class.guardrail_action(guardrail: :prompt_injection, feature: :assistant, account: account)).to eq('block')
      expect(described_class.guardrail_action(guardrail: :sensitive_info, feature: :copilot, account: account)).to eq('block')
    end

    it 'normalizes feature-specific guardrail action preferences' do
      account.update!(
        captain_runtime: {
          'assistant_prompt_injection_guardrail' => 'flag',
          'assistant_sensitive_info_guardrail' => false
        }
      )

      expect(described_class.guardrail_action(guardrail: :prompt_injection, feature: :assistant, account: account)).to eq('flag')
      expect(described_class.guardrail_action(guardrail: :sensitive_info, feature: :assistant, account: account)).to eq('disabled')
    end

    it 'normalizes legacy monitor aliases from runtime preferences' do
      preferences = { 'assistant_prompt_injection_guardrail' => 'monitor' }

      expect(described_class.guardrail_action(guardrail: :prompt_injection, feature: :assistant, preferences: preferences)).to eq('flag')
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

  describe '.web_access_enabled?' do
    it 'defaults web access to disabled' do
      expect(described_class.web_access_enabled?(:search, account: account)).to be(false)
      expect(described_class.web_access_enabled?(:scrape, account: account)).to be(false)
      expect(described_class.web_access_enabled?(:document_parse, account: account)).to be(false)
    end

    it 'reads web access toggles and clamps runtime limits' do
      preferences = {
        'web_search_enabled' => true,
        'web_scrape_enabled' => true,
        'web_document_parse_enabled' => true,
        'web_search_max_results' => 99,
        'web_scrape_max_chars' => 99_999,
        'web_document_parse_max_chars' => 99_999,
        'web_allowed_domains' => ['https://Example.com/docs'],
        'web_blocked_domains' => ['bad.example.com']
      }

      expect(described_class.web_access_enabled?(:search, preferences: preferences)).to be(true)
      expect(described_class.web_access_enabled?(:scrape, preferences: preferences)).to be(true)
      expect(described_class.web_access_enabled?(:document_parse, preferences: preferences)).to be(true)
      expect(described_class.web_search_limit(preferences: preferences)).to eq(10)
      expect(described_class.web_scrape_max_chars(preferences: preferences)).to eq(24_000)
      expect(described_class.web_document_parse_max_chars(preferences: preferences)).to eq(48_000)
      expect(described_class.web_allowed_domains(preferences: preferences)).to eq(['example.com'])
      expect(described_class.web_blocked_domains(preferences: preferences)).to eq(['bad.example.com'])
    end

    it 'reads account runtime preferences without resolving the full Captain model catalog' do
      account.update!(captain_runtime: { 'web_search_enabled' => true })

      expect(account).not_to receive(:captain_preferences)

      expect(described_class.web_access_enabled?(:search, account: account)).to be(true)
    end

    it 'uses the admin upload size and caps document parsing at the provider limit' do
      InstallationConfig.where(name: 'MAXIMUM_FILE_UPLOAD_SIZE').delete_all
      GlobalConfig.clear_cache

      InstallationConfig.create!(name: 'MAXIMUM_FILE_UPLOAD_SIZE', value: 12, locked: false)
      GlobalConfig.clear_cache

      expect(described_class.web_document_parse_max_file_bytes).to eq(12.megabytes)

      InstallationConfig.find_by!(name: 'MAXIMUM_FILE_UPLOAD_SIZE').update!(value: 100)
      GlobalConfig.clear_cache

      expect(described_class.web_document_parse_max_file_bytes).to eq(
        described_class::WEB_DOCUMENT_PARSE_PROVIDER_MAX_FILE_BYTES
      )
    ensure
      InstallationConfig.where(name: 'MAXIMUM_FILE_UPLOAD_SIZE').delete_all
      GlobalConfig.clear_cache
    end
  end
end
