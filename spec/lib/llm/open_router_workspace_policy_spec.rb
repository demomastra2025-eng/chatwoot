# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterWorkspacePolicy do
  describe '.resolve' do
    it 'defaults to a standard dev-safe OpenRouter policy' do
      policy = described_class.resolve

      expect(policy.privacy_profile).to eq('standard')
      expect(policy.workspace).to eq(Rails.env.to_s)
      expect(policy.provider_preferences).to include(
        allow_fallbacks: true,
        data_collection: 'deny',
        zdr: false
      )
      expect(policy.guardrails).to include(
        budget: include(status: 'workspace_required'),
        provider: include(status: 'routing_profile_enforced'),
        model: include(status: 'capability_resolver_enforced'),
        prompt_injection: include(status: 'local_enforced'),
        pii: include(status: 'local_enforced')
      )
    end

    it 'turns sensitive runtime preferences into explicit no-training policy without requiring ZDR' do
      policy = described_class.resolve(preferences: { 'privacy_profile' => 'sensitive' })

      expect(policy.privacy_profile).to eq('sensitive')
      expect(policy.provider_preferences).to include(
        allow_fallbacks: true,
        data_collection: 'deny',
        zdr: false
      )
      expect(policy.trace_capture_allowed?).to be(false)
    end

    it 'reads stored account runtime without materializing Captain model defaults' do
      account = create(:account, captain_runtime: { 'privacy_profile' => 'sensitive' })

      policy = described_class.resolve(account: account)

      expect(policy.privacy_profile).to eq('sensitive')
      expect(policy.trace_capture_allowed?).to be(false)
    end

    it 'merges partial request preferences over stored account runtime policy' do
      account = create(:account, captain_runtime: { 'privacy_profile' => 'zdr_required' })

      policy = described_class.resolve(account: account, preferences: { trace_input_capture: true })

      expect(policy.privacy_profile).to eq('zdr_required')
      expect(policy.provider_preferences).to include(allow_fallbacks: false, zdr: true)
    end

    it 'turns ZDR-required runtime preferences into fail-closed provider routing' do
      policy = described_class.resolve(preferences: { privacy_profile: 'zdr_required' })

      expect(policy.privacy_profile).to eq('zdr_required')
      expect(policy.provider_preferences).to include(
        allow_fallbacks: false,
        data_collection: 'deny',
        zdr: true
      )
      expect(policy.guardrails[:zdr]).to include(status: 'provider_required')
      expect(policy.trace_capture_allowed?).to be(false)
    end

    it 'rejects unsupported privacy profiles clearly' do
      expect do
        described_class.resolve(preferences: { privacy_profile: 'collect_everything' })
      end.to raise_error(ArgumentError, /Unsupported OpenRouter privacy profile/)
    end
  end
end
