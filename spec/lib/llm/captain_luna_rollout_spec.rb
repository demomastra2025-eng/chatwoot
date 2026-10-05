# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CaptainLunaRollout do
  let(:old_model) { 'openai/gpt-5.6-luna' }
  let(:installation_rows) do
    -> { InstallationConfig.where(name: described_class::INSTALLATION_ROWS.keys).order(:name).pluck(:name, :serialized_value) }
  end

  def config_value(name)
    InstallationConfig.find_by(name: name)&.value
  end

  def models_of(account)
    account.reload.captain_models
  end

  def scope_for(*accounts)
    Account.where(id: accounts.map(&:id))
  end

  before do
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_DEFAULT_MODEL').update!(value: old_model)
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPENROUTER_API_KEY').update!(value: 'test-key')
    InstallationConfig.where(name: %w[CAPTAIN_AI_AGENT_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST]).destroy_all
  end

  describe 'the cut-over' do
    it 'moves the installation rows and clears the account choices while keeping the other settings', :aggregate_failures do
      InstallationConfig.where(name: %w[CAPTAIN_IMAGE_RECOGNITION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL]).destroy_all
      old_account = create(:account, captain_models: { 'assistant' => old_model, 'copilot' => 'gpt-5.4', 'audio_transcription' => 'whisper-1' })
      unset_account = create(:account, captain_models: { 'editor' => 'gpt-5.4-mini' })
      already_updated = create(:account, captain_models: { 'assistant' => target_model })
      no_choice = create(:account)
      scope = scope_for(old_account, unset_account, already_updated, no_choice)
      plan = described_class.plan(scope: scope)

      expect(plan[:accounts].pluck(:account_id)).to contain_exactly(old_account.id, unset_account.id, already_updated.id)
      expect(described_class.apply!(plan, scope: scope)).to eq(3)

      expect(models_of(old_account)).to eq('audio_transcription' => 'whisper-1')
      expect(models_of(unset_account)).to eq({})
      expect(models_of(already_updated)).to eq({})
      expect(models_of(no_choice)).to be_blank
      [old_account, unset_account, already_updated, no_choice].each do |account|
        described_class::FEATURES.each do |feature|
          expect(Llm::Config.model_for(feature: feature, account: account)).to eq(target_model)
        end
      end
      expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(target_model)
      expect(config_value('CAPTAIN_IMAGE_RECOGNITION_MODEL')).to eq(target_model)
      expect(config_value('CAPTAIN_LABEL_SUGGESTION_MODEL')).to eq(target_model)
      expect(InstallationConfig.find_by(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL')).to be_nil
    end

    it 'also moves the agent-only default when the installation has one' do
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').update!(value: old_model)
      account = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(account)
      plan = described_class.plan(scope: scope)

      described_class.apply!(plan, scope: scope)

      expect(config_value('CAPTAIN_AI_AGENT_DEFAULT_MODEL')).to eq(target_model)
      expect(Llm::Config.model_for(feature: :assistant, account: account.reload)).to eq(target_model)
    end

    it 'restores exactly the old rows, account choices and voice models', :aggregate_failures do
      InstallationConfig.where(name: 'CAPTAIN_LABEL_SUGGESTION_MODEL').destroy_all
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_IMAGE_RECOGNITION_MODEL').update!(value: 'openai/gpt-5.4-mini')
      old_account = create(:account, captain_models: { 'assistant' => old_model, 'copilot' => 'gpt-5.4', 'audio_transcription' => 'whisper-1' })
      unset_account = create(:account, captain_models: { 'editor' => 'gpt-5.4-mini' })
      already_updated = create(:account, captain_models: { 'assistant' => target_model })
      scope = scope_for(old_account, unset_account, already_updated)
      assistant = voice_assistant(old_account, 'provider' => 'elevenlabs', 'model' => 'openai/gpt-5.4-mini', 'voice' => 'a')
      rows_before = installation_rows.call
      plan = JSON.parse(described_class.plan(scope: scope).to_json)
      described_class.apply!(plan, scope: scope)
      expect(installation_rows.call).not_to eq(rows_before)

      expect(described_class.rollback!(plan)).to eq(3)

      expect(models_of(old_account)).to eq('assistant' => old_model, 'copilot' => 'gpt-5.4', 'audio_transcription' => 'whisper-1')
      expect(models_of(unset_account)).to eq('editor' => 'gpt-5.4-mini')
      expect(models_of(already_updated)).to eq('assistant' => target_model)
      expect(assistant.reload.config.dig('voice_settings', 'model')).to eq('openai/gpt-5.4-mini')
      expect(installation_rows.call).to eq(rows_before)
      expect(described_class.restored_differences(plan)).to be_empty
    end

    it 'restores the effective old model when the installation had no agent-only default and no row of its own' do
      InstallationConfig.where(name: 'CAPTAIN_DEFAULT_MODEL').destroy_all
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_MODEL').update!(value: old_model)
      account = create(:account, captain_models: {})
      scope = scope_for(account)
      plan = described_class.plan(scope: scope)

      described_class.apply!(plan, scope: scope)
      expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(target_model)
      described_class.rollback!(plan)

      expect(InstallationConfig.find_by(name: 'CAPTAIN_DEFAULT_MODEL')).to be_nil
      expect(InstallationConfig.find_by(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL')).to be_nil
      expect(Llm::Config.model_for(feature: :assistant, account: account.reload)).to eq(old_model)
    end

    it 'is idempotent in both directions' do
      account = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(account)
      plan = JSON.parse(described_class.plan(scope: scope).to_json)

      expect(described_class.apply!(plan, scope: scope)).to eq(1)
      expect(described_class.apply!(plan, scope: scope)).to eq(0)
      expect(described_class.rollback!(plan)).to eq(1)
      expect(described_class.rollback!(plan)).to eq(0)
      expect(models_of(account)).to eq('assistant' => old_model)
      expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(old_model)
    end

    it 'does not let an account deleted after the cut-over block the rollback' do
      kept = create(:account, captain_models: { 'assistant' => old_model })
      gone = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(kept, gone)
      plan = described_class.plan(scope: scope)
      described_class.apply!(plan, scope: scope)
      gone.destroy!

      expect(described_class.rollback!(plan)).to eq(1)
      expect(models_of(kept)).to eq('assistant' => old_model)
      expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(old_model)
    end

    it 'follows the platform default afterwards, so the Super Admin default alone moves every account back' do
      account = create(:account, captain_models: { 'assistant' => old_model, 'copilot' => 'gpt-5.4' })
      scope = scope_for(account)
      described_class.apply!(described_class.plan(scope: scope), scope: scope)

      InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').update!(value: old_model)

      expect(Llm::Config.model_for(feature: :assistant, account: account.reload)).to eq(old_model)
      expect(Llm::Config.model_for(feature: :copilot, account: account)).to eq(old_model)
      expect(Llm::Config.model_for(feature: :editor, account: account)).to eq(old_model)
    end

    it 'does not touch an account added after the snapshot, and an account without a choice needs nothing' do
      account = create(:account, captain_models: { 'assistant' => old_model })
      plan = described_class.plan(scope: scope_for(account))
      newcomer = create(:account)

      expect(described_class.apply!(plan, scope: scope_for(account, newcomer))).to eq(1)
      expect(models_of(newcomer)).to be_blank
      expect(Llm::Config.model_for(feature: :assistant, account: newcomer)).to eq(target_model)
      expect(described_class.rollback!(plan)).to eq(1)
      expect(models_of(newcomer)).to be_blank
    end

    it 'moves an account whose choice is outside the allowlist or no longer valid without breaking it' do
      outside = create(:account, captain_models: { 'copilot' => 'claude-sonnet-4-6', 'assistant' => 'gpt-5.1' })
      retired = create(:account, captain_models: { 'assistant' => old_model })
      retired.captain_models = { 'assistant' => 'vendor/retired', 'audio_transcription' => 'vendor/gone' }
      retired.save!(validate: false)
      scope = scope_for(outside, retired)
      plan = described_class.plan(scope: scope)

      expect(described_class.apply!(plan, scope: scope)).to eq(2)

      expect(models_of(outside)).to eq({})
      expect(models_of(retired)).to eq('audio_transcription' => 'vendor/gone')
      expect(Llm::Config.model_for(feature: :assistant, account: retired)).to eq(target_model)
      expect(Llm::Config.model_for(feature: :copilot, account: outside)).to eq(target_model)
      described_class.rollback!(plan)
      expect(models_of(outside)).to eq('copilot' => 'claude-sonnet-4-6', 'assistant' => 'gpt-5.1')
      expect(models_of(retired)).to eq('assistant' => 'vendor/retired', 'audio_transcription' => 'vendor/gone')
    end

    it 'guards apply and rollback without scanning the model catalog for every Captain feature' do
      old_account = create(:account, captain_models: { 'assistant' => old_model })
      unset_account = create(:account, captain_models: { 'copilot' => 'gpt-5.4' })
      scope = scope_for(old_account, unset_account)
      plan = described_class.plan(scope: scope)
      selects = 0
      count_select = lambda do |*, payload|
        selects += 1 if payload[:name] != 'SCHEMA' && !payload[:cached] && payload[:sql].to_s.lstrip.start_with?('SELECT')
      end

      ActiveSupport::Notifications.subscribed(count_select, 'sql.active_record') do
        expect(described_class.apply!(plan, scope: scope)).to eq(2)
        expect(described_class.rollback!(plan)).to eq(2)
      end

      expect(selects).to be < 500
    end
  end

  describe 'refusals' do
    it 'rejects a stale plan without changing anything' do
      first = create(:account, captain_models: { 'assistant' => old_model })
      second = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(first, second)
      plan = described_class.plan(scope: scope)
      second.update!(captain_models: { 'assistant' => target_model })

      expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan, /changed since the snapshot/)
      expect(models_of(first)).to eq('assistant' => old_model)
      expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(old_model)
    end

    it 'rejects a plan when an account gained a choice after the snapshot' do
      account = create(:account, captain_models: { 'assistant' => old_model })
      other = create(:account)
      scope = scope_for(account, other)
      plan = described_class.plan(scope: scope)
      other.update!(captain_models: { 'copilot' => 'gpt-5.4' })

      expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan, /changed since the snapshot/)
      expect(models_of(account)).to eq('assistant' => old_model)
    end

    it 'rejects a plan when an account of the snapshot disappeared' do
      account = create(:account, captain_models: { 'assistant' => old_model })
      gone = create(:account, captain_models: { 'assistant' => old_model })
      plan = described_class.plan(scope: scope_for(account, gone))
      gone.destroy!

      expect { described_class.apply!(plan, scope: scope_for(account)) }.to raise_error(described_class::StalePlan, /Account list changed/)
      expect(models_of(account)).to eq('assistant' => old_model)
    end

    it 'rejects a plan when the installation default changed after the snapshot' do
      account = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(account)
      plan = described_class.plan(scope: scope)
      InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').update!(value: 'openai/gpt-5.4-mini')

      expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan, /CAPTAIN_DEFAULT_MODEL changed/)
      expect(models_of(account)).to eq('assistant' => old_model)
    end

    it 'rejects a snapshot taken after the Luna 6 default was already installed' do
      InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').update!(value: target_model)

      expect { described_class.plan(scope: scope_for(create(:account))) }.to raise_error(described_class::StalePlan, /already installed/)
    end

    it 'rejects a snapshot when no installation row records what the accounts inherit today' do
      %w[CAPTAIN_DEFAULT_MODEL CAPTAIN_OPEN_AI_MODEL].each { |name| InstallationConfig.find_by(name: name)&.destroy! }
      account = create(:account, captain_models: {})

      expect { described_class.plan(scope: scope_for(account)) }.to raise_error(described_class::StalePlan, /already Luna 6/)
    end

    it 'does not partially roll back when a choice was changed after the cut-over' do
      first = create(:account, captain_models: { 'assistant' => old_model })
      second = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(first, second)
      plan = described_class.plan(scope: scope)
      described_class.apply!(plan, scope: scope)
      second.update!(captain_models: { 'assistant' => target_model })

      expect { described_class.rollback!(plan) }.to raise_error(described_class::StalePlan, /changed since the snapshot/)
      expect(models_of(first)).to eq({})
      expect(models_of(second)).to eq('assistant' => target_model)
      expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(target_model)
    end

    it 'refuses a snapshot of another version or target' do
      plan = described_class.plan(scope: scope_for(create(:account)))

      expect { described_class.apply!(plan.merge(version: 1)) }.to raise_error(described_class::StalePlan, /version/)
      expect { described_class.rollback!(plan.merge(target_model: 'openai/gpt-5.4')) }.to raise_error(described_class::StalePlan, /target/)
    end

    [
      { 'openrouter_allow_model_fallbacks' => false },
      { 'privacy_profile' => 'zdr_required' }
    ].each do |runtime_settings|
      it "rejects an account whose runtime disables the Luna route: #{runtime_settings.keys.first}" do
        account = create(:account, captain_models: { 'assistant' => old_model }, captain_runtime: runtime_settings)
        scope = scope_for(account)

        expect { described_class.plan(scope: scope) }.to raise_error(described_class::StalePlan, /fallback/)
        expect(models_of(account)).to eq('assistant' => old_model)
        expect(config_value('CAPTAIN_DEFAULT_MODEL')).to eq(old_model)
      end
    end

    it 'refuses to cut over when the allowlist would not keep both Luna models selectable' do
      account = create(:account, captain_models: { 'assistant' => old_model })
      scope = scope_for(account)
      plan = described_class.plan(scope: scope)
      InstallationConfig.create!(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', value: '["openai/gpt-6-luna"]')

      expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan, /allowlist/)
      expect(models_of(account)).to eq('assistant' => old_model)
    end
  end

  describe 'the voice agent settings' do
    it 'moves the OpenRouter providers in the agent and in the routing policy and leaves the speech-to-speech providers' do
      account = create(:account)
      scope = scope_for(account)
      cascade = voice_assistant(account, 'provider' => 'elevenlabs', 'model' => 'openai/gpt-5.4-mini', 'voice' => 'a')
      cartesia = voice_assistant(account, 'provider' => 'cartesia', 'model' => 'openai/gpt-5.6-luna', 'voice' => 'b')
      fish = voice_assistant(account, 'provider' => 'elevenlabs', 'model' => 'openai/gpt-5.4', 'voice' => 'c')
      fish.config = { 'voice_settings' => { 'provider' => 'fish', 'model' => 'openai/gpt-5.4-mini', 'voice' => 'd' } }
      fish.save!(validate: false)
      native = voice_assistant(account, 'provider' => 'gemini-live', 'model' => 'gemini-3.1-flash-live-preview', 'voice' => 'sulafat')
      no_model = voice_assistant(account, 'provider' => 'elevenlabs', 'voice' => 'e')
      policy = create(:telephony_routing_policy, account: account,
                                                 ai_voice_settings: { 'provider' => 'elevenlabs', 'model' => 'openai/gpt-5.4-mini',
                                                                      'language' => 'ru-KZ' })
      plan = described_class.plan(scope: scope)

      expect(plan[:voice].pluck(:store, :id)).to contain_exactly(
        ['captain_assistant', cascade.id], ['captain_assistant', cartesia.id], ['captain_assistant', fish.id], ['routing_policy', policy.id]
      )
      described_class.apply!(plan, scope: scope)

      [cascade, cartesia, fish].each { |assistant| expect(assistant.reload.config.dig('voice_settings', 'model')).to eq(target_model) }
      expect(policy.reload.ai_voice_settings).to include('model' => target_model, 'language' => 'ru-KZ')
      expect(native.reload.config.dig('voice_settings', 'model')).to eq('gemini-3.1-flash-live-preview')
      expect(no_model.reload.config['voice_settings']).not_to have_key('model')
      described_class.rollback!(plan)
      expect(cartesia.reload.config.dig('voice_settings', 'model')).to eq('openai/gpt-5.6-luna')
      expect(policy.reload.ai_voice_settings['model']).to eq('openai/gpt-5.4-mini')
    end

    it 'refuses when the provider of a stored voice setting changed after the snapshot' do
      account = create(:account)
      scope = scope_for(account)
      assistant = voice_assistant(account, 'provider' => 'elevenlabs', 'model' => 'openai/gpt-5.4-mini', 'voice' => 'a')
      plan = described_class.plan(scope: scope)
      assistant.config = { 'voice_settings' => { 'provider' => 'gemini-live', 'model' => 'openai/gpt-5.4-mini' } }
      assistant.save!(validate: false)

      expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan, /Voice settings/)
      expect(assistant.reload.config.dig('voice_settings', 'model')).to eq('openai/gpt-5.4-mini')
    end

    it 'sends the cut-over model to the voice runtime in the context payload' do
      account = create(:account)
      assistant = voice_assistant(account, 'provider' => 'elevenlabs', 'model' => 'openai/gpt-5.4-mini', 'voice' => 'a')
      scope = scope_for(account)
      described_class.apply!(described_class.plan(scope: scope), scope: scope)

      normalized = Telephony::AiVoice::VoiceSettingsDefaults.normalize(assistant.reload.config['voice_settings'])

      expect(normalized).to include('provider' => 'elevenlabs', 'model' => target_model)
    end
  end

  describe Llm::CaptainLunaRollout::Snapshot do
    let(:path) { Rails.root.join("tmp/luna_snapshot_spec_#{SecureRandom.hex(4)}.json") }

    after { FileUtils.rm_f(path) }

    it 'writes a private file that holds ids and model ids only, and verifies it' do
      account = create(:account, name: 'Private Name LLC', captain_models: { 'assistant' => old_model })
      plan = Llm::CaptainLunaRollout.plan(scope: Account.where(id: account.id))

      described_class.write(plan, path)

      expect(path.stat.mode & 0o777).to eq(0o600)
      content = path.read
      expect(content).not_to include('Private Name LLC')
      expect(content).not_to include('test-key')
      expect(JSON.parse(content)).to include('target_model' => target_model, 'version' => 2)
      expect(described_class.read(path)).to eq(JSON.parse(JSON.generate(plan)))
    end

    it 'never overwrites a file' do
      plan = Llm::CaptainLunaRollout.plan(scope: Account.where(id: create(:account).id))
      File.write(path, 'precious')

      expect { described_class.write(plan, path) }.to raise_error(described_class::Error, /already exists/)
      expect(path.read).to eq('precious')
    end

    it 'refuses to read a snapshot that other users can access or that is not JSON' do
      File.write(path, '{}')
      File.chmod(0o644, path)
      expect { described_class.read(path) }.to raise_error(described_class::Error, /0600/)

      File.chmod(0o600, path)
      File.write(path, 'not json')
      expect { described_class.read(path) }.to raise_error(described_class::Error, /not valid JSON/)
      expect { described_class.read("#{path}.missing") }.to raise_error(described_class::Error, /does not exist/)
    end
  end

  describe Llm::CaptainLunaRollout::Preview do
    it 'counts the changes per feature and old model with account ids only, and flags choices outside the allowlist' do
      account = create(:account, name: 'Private Name LLC', captain_models: { 'assistant' => old_model, 'copilot' => 'claude-sonnet-4-6' })
      other = create(:account, captain_models: { 'assistant' => old_model })
      plan = Llm::CaptainLunaRollout.plan(scope: Account.where(id: [account.id, other.id]))

      text = described_class.new(JSON.parse(JSON.generate(plan)), target: target_model).to_s

      expect(text).to include("CAPTAIN_DEFAULT_MODEL: #{old_model} -> #{target_model}")
      expect(text).to include(%(assistant: "#{old_model}" x2 accounts #{account.id}, #{other.id}))
      expect(text).to match(/copilot: "claude-sonnet-4-6" x1 \[outside the allowlist\] accounts #{account.id}/)
      expect(text).not_to include('Private Name LLC')
    end
  end

  def target_model
    Llm::CaptainLunaRollout::TARGET_MODEL
  end

  def voice_assistant(account, settings)
    create(:captain_assistant, account: account, config: { 'voice_settings' => settings })
  end
end
