# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CaptainFeaturable do
  let(:account) { create(:account) }

  describe 'dynamic method generation' do
    it 'generates enabled? methods for all features' do
      Llm::Models.feature_keys.each do |feature_key|
        expect(account).to respond_to("captain_#{feature_key}_enabled?")
      end
    end

    it 'generates model accessor methods for all features' do
      Llm::Models.feature_keys.each do |feature_key|
        expect(account).to respond_to("captain_#{feature_key}_model")
      end
    end
  end

  describe 'feature enabled methods' do
    let(:opt_in_feature_keys) { Llm::Models.feature_keys - [described_class::TEXT_IMPROVEMENT_FEATURE_KEY] }

    context 'when no features are explicitly enabled' do
      it 'returns false for all opt-in features' do
        opt_in_feature_keys.each do |feature_key|
          expect(account.send("captain_#{feature_key}_enabled?")).to be false
        end
      end

      it 'keeps text improvement (editor) on' do
        expect(account.captain_editor_enabled?).to be true
      end
    end

    context 'when an admin switched text improvement off in the new switch' do
      before do
        account.update!(captain_features: { 'text_improvement' => false, 'label_suggestion' => true })
      end

      it 'returns false for the editor only' do
        expect(account.captain_editor_enabled?).to be false
        expect(account.captain_label_suggestion_enabled?).to be true
      end
    end

    # The AI settings page had a per-feature editor switch in 2026-01..05; a
    # false stored back then must not remove the writing tools on deploy.
    context 'when only a legacy editor value is stored' do
      it 'keeps text improvement on for a legacy false' do
        account.update!(captain_features: { 'editor' => false })

        expect(account.captain_editor_enabled?).to be true
        expect(account.captain_preferences[:features]['editor']).to be true
      end

      it 'lets the new switch decide once it has been saved' do
        account.update!(captain_features: { 'editor' => false, 'text_improvement' => true })
        expect(account.captain_editor_enabled?).to be true

        account.update!(captain_features: { 'editor' => true, 'text_improvement' => false })
        expect(account.captain_editor_enabled?).to be false
      end
    end

    context 'when the stored text improvement value is null' do
      before do
        account.update!(captain_features: { 'text_improvement' => nil })
      end

      it 'keeps text improvement on' do
        expect(account.captain_editor_enabled?).to be true
      end
    end

    context 'when features are explicitly enabled' do
      before do
        account.update!(captain_features: { 'editor' => true, 'assistant' => true })
      end

      it 'returns true for enabled features' do
        expect(account.captain_editor_enabled?).to be true
        expect(account.captain_assistant_enabled?).to be true
      end

      it 'returns false for disabled features' do
        expect(account.captain_copilot_enabled?).to be false
        expect(account.captain_label_suggestion_enabled?).to be false
      end
    end

    context 'when captain_features is nil' do
      before do
        account.update!(captain_features: nil)
      end

      it 'returns false for all opt-in features and keeps text improvement on' do
        opt_in_feature_keys.each do |feature_key|
          expect(account.send("captain_#{feature_key}_enabled?")).to be false
        end
        expect(account.captain_editor_enabled?).to be true
      end
    end
  end

  describe 'model accessor methods' do
    context 'when no models are explicitly configured' do
      it 'returns default models for all features' do
        Llm::Models.feature_keys.each do |feature_key|
          expected_default = Llm::Models.default_model_for(feature_key)
          expect(account.send("captain_#{feature_key}_model")).to eq(expected_default)
        end
      end
    end

    context 'when models are explicitly configured' do
      before do
        account.update!(captain_models: {
                          'editor' => 'gpt-4.1-mini',
                          'assistant' => 'gpt-5.1',
                          'label_suggestion' => 'gpt-4.1-nano'
                        })
      end

      it 'returns configured models for configured features' do
        expect(account.captain_editor_model).to eq('gpt-4.1-mini')
        expect(account.captain_assistant_model).to eq('gpt-5.1')
        expect(account.captain_label_suggestion_model).to eq('gpt-4.1-nano')
      end

      it 'returns default models for unconfigured features' do
        expect(account.captain_copilot_model).to eq(Llm::Models.default_model_for('copilot'))
        expect(account.captain_audio_transcription_model).to eq(Llm::Models.default_model_for('audio_transcription'))
      end
    end

    context 'when configured with invalid model' do
      before do
        account.captain_models = { 'editor' => 'invalid-model' }
      end

      it 'falls back to default model' do
        expect(account.captain_editor_model).to eq(Llm::Models.default_model_for('editor'))
      end
    end

    context 'when configured with a legacy Anthropic alias' do
      before do
        account.captain_models = { 'assistant' => 'claude-sonnet-4.6' }
      end

      it 'returns the canonical Anthropic model id' do
        expect(account.captain_assistant_model).to eq('claude-sonnet-4-6')
      end
    end

    context 'when captain_models is nil' do
      before do
        account.update!(captain_models: nil)
      end

      it 'returns default models for all features' do
        Llm::Models.feature_keys.each do |feature_key|
          expected_default = Llm::Models.default_model_for(feature_key)
          expect(account.send("captain_#{feature_key}_model")).to eq(expected_default)
        end
      end
    end
  end

  describe 'integration with existing captain_preferences' do
    it 'enabled? methods use the same logic as captain_preferences[:features]' do
      account.update!(captain_features: { 'editor' => true, 'copilot' => true })
      prefs = account.captain_preferences

      Llm::Models.feature_keys.each do |feature_key|
        expect(account.send("captain_#{feature_key}_enabled?")).to eq(prefs[:features][feature_key])
      end
    end

    it 'model methods use the same logic as captain_preferences[:models]' do
      account.update!(captain_models: { 'editor' => 'gpt-4.1-mini', 'assistant' => 'gpt-5.2' })
      prefs = account.captain_preferences

      Llm::Models.feature_keys.each do |feature_key|
        expect(account.send("captain_#{feature_key}_model")).to eq(prefs[:models][feature_key])
      end
    end

    it 'exposes runtime preferences with defaults' do
      prefs = account.captain_preferences

      expect(prefs[:runtime]).to include(
        'assistant_thinking_effort' => 'none',
        'copilot_thinking_effort' => 'none',
        'assistant_moderation' => false,
        'copilot_moderation' => false,
        'assistant_prompt_injection_guardrail' => 'block',
        'copilot_prompt_injection_guardrail' => 'block',
        'assistant_sensitive_info_guardrail' => 'block',
        'copilot_sensitive_info_guardrail' => 'block',
        'knowledge_chunk_size' => Captain::KnowledgeSettings::DEFAULT_CHUNK_SIZE,
        'trace_input_capture' => true,
        'trace_output_capture' => true
      )
      expect(account.captain_assistant_thinking_effort).to eq('none')
      expect(account.captain_assistant_moderation?).to be false
      expect(account.captain_copilot_moderation?).to be false
      expect(account.captain_knowledge_chunk_size).to eq(Captain::KnowledgeSettings::DEFAULT_CHUNK_SIZE)
      expect(account.captain_trace_input_capture?).to be true
      expect(account.captain_trace_output_capture?).to be true
    end

    it 'returns stored runtime preferences when configured' do
      account.update!(captain_runtime: {
                        'assistant_thinking_effort' => 'high',
                        'copilot_moderation' => true,
                        'knowledge_chunk_size' => 24_000,
                        'trace_input_capture' => false,
                        'trace_output_capture' => false
                      })

      expect(account.captain_assistant_thinking_effort).to eq('high')
      expect(account.captain_copilot_moderation?).to be true
      expect(account.captain_knowledge_chunk_size).to eq(24_000)
      expect(account.captain_trace_input_capture?).to be false
      expect(account.captain_trace_output_capture?).to be false
    end
  end

  describe 'the short assistant model list curated by the platform' do
    let(:allowlisted_model) { 'openai/gpt-5.6-luna' }
    let(:other_model) { 'openai/gpt-6-luna' }

    context 'when the platform curated a list' do
      before { upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', JSON.generate([allowlisted_model])) }

      # What an account may newly choose is decided by the preferences API (and the AI agent form); the account
      # record itself stays permissive so that internal tools such as the model rollout can still write models.
      it 'does not make the account record refuse a model that is technically valid' do
        expect(account.update(captain_models: { 'assistant' => other_model })).to be true
        expect(account.captain_assistant_model).to eq(other_model)
      end

      it 'accepts a model from the list' do
        expect(account.update(captain_models: { 'assistant' => allowlisted_model })).to be true
        expect(account.captain_assistant_model).to eq(allowlisted_model)
      end
    end

    context 'when the list is introduced after an account chose a model outside it' do
      let(:stored_account) do
        upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
        create(:account, captain_models: { 'assistant' => other_model }).tap do
          upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', JSON.generate([allowlisted_model]))
        end
      end

      it 'keeps the stored model working at runtime' do
        reloaded_account = Account.find(stored_account.id)

        expect(reloaded_account.captain_assistant_model).to eq(other_model)
        expect(Llm::Config.model_for(feature: :assistant, account: reloaded_account)).to eq(other_model)
      end

      it 'keeps the account valid while it changes other settings or other models' do
        reloaded_account = Account.find(stored_account.id)

        expect(reloaded_account.update(captain_features: { 'assistant' => true })).to be true
        expect(reloaded_account.update(captain_models: reloaded_account.captain_models.merge('editor' => 'gpt-4.1-mini'))).to be true
        expect(reloaded_account.captain_assistant_model).to eq(other_model)
      end
    end

    context 'when the list is blank or malformed' do
      it 'does not restrict anything while it is blank' do
        expect(Llm::Models.configured_model_allowlist).to be_nil
        expect(account.update(captain_models: { 'assistant' => other_model })).to be true
      end

      it 'ignores a malformed list instead of locking every assistant model out' do
        upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '{not json')

        expect(Llm::Models.configured_model_allowlist).to be_nil
        expect(account.update(captain_models: { 'assistant' => other_model })).to be true
      end

      it 'offers the built-in short list to the client' do
        expect(Llm::Models.curated_model_names_for('assistant')).to all(satisfy do |model|
          Llm::Models::DEFAULT_CURATED_MODELS.include?(model)
        end)
      end
    end
  end
end
