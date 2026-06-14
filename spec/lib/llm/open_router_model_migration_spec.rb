# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterModelMigration do
  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
  end

  describe '.resolve' do
    it 'maps legacy direct chat model ids to OpenRouter equivalents for normal Captain features' do
      stub_openrouter_catalog(
        'openai/gpt-5.4' => chat_model_config,
        'anthropic/claude-sonnet-4-6' => chat_model_config,
        'google/gemini-2.5-pro' => chat_model_config
      )

      expect(described_class.resolve('gpt-5.4', feature: :assistant)).to eq('openai/gpt-5.4')
      expect(described_class.resolve('claude-sonnet-4.6', feature: :assistant)).to eq('anthropic/claude-sonnet-4-6')
      expect(described_class.resolve('gemini-2.5-pro', feature: :assistant)).to eq('google/gemini-2.5-pro')
    end

    it 'maps legacy audio, moderation, and embedding ids through explicit OpenRouter candidates' do
      stub_openrouter_catalog(
        'openai/gpt-4o-transcribe' => {
          'provider' => 'openrouter',
          'type' => 'transcription',
          'capabilities' => %w[audio_input transcription]
        },
        'openai/gpt-oss-safeguard-20b' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output moderation]
        },
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1536,
          'context_length' => 8192
        }
      )

      expect(described_class.resolve('gpt-4o-transcribe', feature: :audio_transcription)).to eq('openai/gpt-4o-transcribe')
      expect(described_class.resolve('omni-moderation-latest', feature: :moderation)).to eq('openai/gpt-oss-safeguard-20b')
      expect(described_class.resolve('text-embedding-3-small', feature: :help_center_search)).to eq('openai/text-embedding-3-small')
    end

    it 'does not map Gemini Live voice model ids' do
      stub_openrouter_catalog(
        'google/gemini-3.1-flash-live-preview' => chat_model_config
      )

      expect(described_class.resolve('gemini-live', feature: :ai_voice)).to eq('gemini-live')
      expect(described_class.resolve('gemini-3.1-flash-live-preview', feature: :telephony_ai_voice)).to eq('gemini-3.1-flash-live-preview')
    end

    it 'returns nil when OpenRouter has no compatible normal-feature target' do
      stub_openrouter_catalog(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        }
      )

      expect(described_class.resolve('gpt-5.4', feature: :assistant)).to be_nil
    end
  end

  describe '.dry_run' do
    it 'produces a per-account migration report without mutating stored settings' do
      stub_full_openrouter_catalog
      account = create_account_with_captain_models(
        'assistant' => 'gpt-5.4',
        'copilot' => 'claude-sonnet-4.6',
        'image_recognition' => 'gemini-2.5-pro',
        'audio_transcription' => 'whisper-1',
        'moderation' => 'omni-moderation-latest',
        'help_center_search' => 'text-embedding-3-small',
        'telephony_ai_voice' => 'gemini-3.1-flash-live-preview'
      )
      unmapped_account = create_account_with_captain_models('assistant' => 'legacy-direct-only')

      report = described_class.dry_run(scope: Account.where(id: [account.id, unmapped_account.id]))

      expect(report[:mode]).to eq('dry_run')
      expect(report[:totals]).to include(
        accounts_scanned: 2,
        accounts_with_captain_models: 2,
        accounts_with_changes: 1,
        model_changes: 6,
        unmapped_models: 1,
        voice_models_unchanged: 1,
        direct_openai_models: 4,
        direct_anthropic_models: 1,
        direct_gemini_models: 1,
        global_openrouter_configured: true,
        account_openrouter_configured: 0
      )
      expect(report_for(report, account)[:changes]).to include(
        include(feature: 'assistant', from: 'gpt-5.4', to: 'openai/gpt-5.4', status: 'mapped'),
        include(feature: 'copilot', from: 'claude-sonnet-4.6', to: 'anthropic/claude-sonnet-4-6', status: 'mapped'),
        include(feature: 'image_recognition', from: 'gemini-2.5-pro', to: 'google/gemini-2.5-pro', status: 'mapped'),
        include(feature: 'telephony_ai_voice', from: 'gemini-3.1-flash-live-preview', to: 'gemini-3.1-flash-live-preview', status: 'voice_skipped')
      )
      expect(report_for(report, account)[:rollback]).to include(
        'assistant' => 'gpt-5.4',
        'telephony_ai_voice' => 'gemini-3.1-flash-live-preview'
      )
      expect(report_for(report, unmapped_account)[:changes]).to include(
        include(feature: 'assistant', from: 'legacy-direct-only', to: nil, status: 'unmapped')
      )
      expect(account.reload.captain_models['assistant']).to eq('gpt-5.4')
    end
  end

  describe '.apply!' do
    it 'persists mapped OpenRouter model ids while preserving voice Gemini settings' do
      stub_full_openrouter_catalog
      account = create_account_with_captain_models(
        'assistant' => 'gpt-5.4',
        'audio_transcription' => 'whisper-1',
        'voice_settings' => 'gemini-live',
        'editor' => ''
      )

      report = described_class.apply!(scope: Account.where(id: account.id))

      expect(report[:mode]).to eq('apply')
      expect(report[:totals]).to include(accounts_updated: 1, model_changes: 2, voice_models_unchanged: 1)
      expect(account.reload.captain_models).to include(
        'assistant' => 'openai/gpt-5.4',
        'audio_transcription' => 'openai/gpt-4o-mini-transcribe',
        'voice_settings' => 'gemini-live',
        'editor' => ''
      )
    end

    it 'blocks apply when normal Captain models cannot be mapped' do
      stub_full_openrouter_catalog
      mappable_account = create_account_with_captain_models('assistant' => 'gpt-5.4')
      unmapped_account = create_account_with_captain_models('assistant' => 'legacy-direct-only')

      expect do
        described_class.apply!(scope: Account.where(id: [mappable_account.id, unmapped_account.id]))
      end.to raise_error(described_class::UnmappedModelsError)
      expect(mappable_account.reload.captain_models['assistant']).to eq('gpt-5.4')
    end
  end

  describe '.audit' do
    it 'passes when normal Captain features only store OpenRouter models while voice keeps Gemini direct models' do
      stub_full_openrouter_catalog
      account = create_account_with_captain_models(
        'assistant' => 'openai/gpt-5.4',
        'help_center_search' => 'openai/text-embedding-3-small',
        'voice_settings' => 'gemini-live'
      )

      report = described_class.audit(scope: Account.where(id: account.id))

      expect(report).to include(
        mode: 'audit',
        passed: true,
        status: 'passed',
        blocking_issues: []
      )
      expect(report[:totals]).to include(
        blocking_issues: 0,
        voice_models_unchanged: 1
      )
    end

    it 'fails when legacy direct models are still stored for normal Captain features' do
      stub_full_openrouter_catalog
      account = create_account_with_captain_models(
        'assistant' => 'gpt-5.4',
        'copilot' => 'legacy-direct-only'
      )

      report = described_class.audit(scope: Account.where(id: account.id))

      expect(report).to include(
        mode: 'audit',
        passed: false,
        status: 'failed'
      )
      expect(report[:totals]).to include(blocking_issues: 2)
      expect(report[:blocking_issues]).to include(
        include(
          account_id: account.id,
          feature: 'assistant',
          from: 'gpt-5.4',
          to: 'openai/gpt-5.4',
          reason: 'legacy_direct_model_still_stored'
        ),
        include(
          account_id: account.id,
          feature: 'copilot',
          from: 'legacy-direct-only',
          to: nil,
          reason: 'unmapped_legacy_model'
        )
      )
    end
  end

  describe '.rollback_from_report!' do
    it 'restores stored Captain models from a migration report' do
      account = create_account_with_captain_models('assistant' => 'openai/gpt-5.4')
      report_path = Rails.root.join('tmp/openrouter_model_migration_rollback_spec.json')
      report_path.write(
        JSON.pretty_generate(
          accounts: [
            {
              account_id: account.id,
              rollback: { 'assistant' => 'gpt-5.4', 'voice_settings' => 'gemini-live' }
            },
            {
              account_id: -1,
              rollback: { 'assistant' => 'missing-account' }
            }
          ]
        )
      )

      report = described_class.rollback_from_report!(report_path)

      expect(report).to include(mode: 'rollback', restored_accounts: 1, source_report: report_path.to_s)
      expect(account.reload.captain_models).to include(
        'assistant' => 'gpt-5.4',
        'voice_settings' => 'gemini-live'
      )
    ensure
      FileUtils.rm_f(report_path)
    end
  end

  describe '.write_report' do
    it 'exports a reversible JSON report under the requested directory' do
      report = {
        mode: 'dry_run',
        totals: { accounts_scanned: 1 },
        accounts: [{ account_id: 123, rollback: { 'assistant' => 'gpt-5.4' } }]
      }
      directory = Rails.root.join('tmp/openrouter_model_migration_spec')
      FileUtils.rm_rf(directory)

      path = described_class.write_report(report, directory: directory, timestamp: Time.utc(2026, 5, 30, 12, 0, 0))

      expect(path).to eq(directory.join('openrouter_model_migration-dry_run-20260530T120000Z.json'))
      expect(JSON.parse(path.read)).to include(
        'mode' => 'dry_run',
        'accounts' => [include('account_id' => 123, 'rollback' => { 'assistant' => 'gpt-5.4' })]
      )
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def stub_openrouter_catalog(configs)
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(configs)
  end

  def stub_full_openrouter_catalog
    stub_openrouter_catalog(
      'openai/gpt-5.4' => chat_model_config,
      'anthropic/claude-sonnet-4-6' => chat_model_config,
      'google/gemini-2.5-pro' => chat_model_config.merge('capabilities' => %w[structured_output tool_calling tool_choice image_input]),
      **native_openrouter_model_configs
    )
  end

  def native_openrouter_model_configs
    {
      'openai/gpt-4o-mini-transcribe' => transcription_model_config,
      'openai/gpt-oss-safeguard-20b' => moderation_model_config,
      'openai/text-embedding-3-small' => embedding_model_config
    }
  end

  def create_account_with_captain_models(models)
    create(:account).tap do |account|
      settings = account.settings.to_h.merge('captain_models' => models)
      account.update_columns(settings: settings) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def report_for(report, account)
    report[:accounts].find { |entry| entry[:account_id] == account.id }
  end

  def chat_model_config
    {
      'provider' => 'openrouter',
      'type' => 'chat',
      'capabilities' => %w[structured_output tool_calling tool_choice streaming]
    }
  end

  def transcription_model_config
    {
      'provider' => 'openrouter',
      'type' => 'transcription',
      'capabilities' => %w[audio_input transcription]
    }
  end

  def moderation_model_config
    {
      'provider' => 'openrouter',
      'type' => 'chat',
      'capabilities' => %w[text_input text_output structured_output moderation]
    }
  end

  def embedding_model_config
    {
      'provider' => 'openrouter',
      'type' => 'embedding',
      'capabilities' => %w[embedding text_input],
      'embedding_dimensions' => 1536,
      'context_length' => 8192
    }
  end
end
