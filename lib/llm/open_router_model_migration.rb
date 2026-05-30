# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class Llm::OpenRouterModelMigration
  class UnmappedModelsError < StandardError; end

  REPORT_PREFIX = 'openrouter_model_migration'
  DEFAULT_REPORT_DIRECTORY = Rails.root.join('logs')
  VOICE_FEATURES = %w[
    voice_settings
    ai_voice_settings
    voice
    ai_voice
    telephony_ai_voice
    realtime_voice
    gemini_live
  ].freeze

  EXACT_MAPPINGS = {
    'whisper-1' => %w[openai/whisper-large-v3 openai/gpt-4o-mini-transcribe openai/gpt-4o-transcribe],
    'gpt-4o-transcribe' => %w[openai/gpt-4o-transcribe openai/gpt-4o-mini-transcribe],
    'omni-moderation-latest' => %w[openai/gpt-oss-safeguard-20b meta-llama/llama-guard-4-12b meta-llama/llama-guard-3-8b],
    'text-embedding-3-small' => %w[openai/text-embedding-3-small text-embedding-3-small]
  }.freeze

  class << self
    def resolve(model_name, feature:, account: nil)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return if canonical_model.blank?
      return canonical_model if voice_feature?(feature)
      return canonical_model unless openrouter_required_for?(feature, account: account)

      candidates_for(canonical_model).find do |candidate|
        Llm::Models.valid_model_for?(feature, candidate, account: account)
      end
    end

    def candidates_for(model_name)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return [] if canonical_model.blank?

      candidates = []
      candidates << canonical_model if canonical_model.include?('/')
      candidates.concat(EXACT_MAPPINGS.fetch(canonical_model, []))
      candidates << "openai/#{canonical_model}" if openai_model_id?(canonical_model)
      candidates << "anthropic/#{canonical_model}" if anthropic_model_id?(canonical_model)
      candidates << "google/#{canonical_model}" if gemini_model_id?(canonical_model)
      candidates << canonical_model
      candidates.compact_blank.uniq
    end

    def migrate_models_hash(models_hash, account: nil)
      models_hash.to_h.each_with_object({}) do |(feature, model_name), result|
        result[feature.to_s] = resolve(model_name, feature: feature, account: account) || Llm::Models.canonical_model_name(model_name)
      end
    end

    def dry_run(scope: Account.all, timestamp: Time.current)
      build_report(scope: scope, mode: 'dry_run', timestamp: timestamp)
    end

    def apply!(scope: Account.all, allow_unmapped: false, timestamp: Time.current)
      report = build_report(scope: scope, mode: 'apply', timestamp: timestamp)
      if report.dig(:totals, :unmapped_models).positive? && !allow_unmapped
        raise UnmappedModelsError, "#{report.dig(:totals, :unmapped_models)} OpenRouter model mapping(s) are unresolved"
      end

      updated_count = 0
      Account.transaction do
        report[:accounts].select { |entry| entry[:changed] }.each do |entry|
          account = Account.find(entry[:account_id])
          update_account_models(account, entry[:after])
          updated_count += 1
        end
      end
      report[:totals][:accounts_updated] = updated_count
      report[:applied_at] = Time.current.iso8601
      report
    end

    def write_report(report, directory: DEFAULT_REPORT_DIRECTORY, timestamp: Time.current)
      directory = Pathname.new(directory.to_s)
      FileUtils.mkdir_p(directory)
      mode = report[:mode] || report['mode'] || 'report'
      filename = "#{REPORT_PREFIX}-#{mode}-#{timestamp.utc.strftime('%Y%m%dT%H%M%SZ')}.json"
      path = directory.join(filename)
      path.write("#{JSON.pretty_generate(report.deep_stringify_keys)}\n")
      path
    end

    def voice_feature?(feature)
      VOICE_FEATURES.include?(feature.to_s)
    end

    private

    def build_report(scope:, mode:, timestamp:)
      totals = initial_totals
      accounts = []

      Llm::Config.with_runtime_cache do
        each_account(scope) { |account| scan_account(account, totals, accounts) }
      end

      migration_report(mode: mode, timestamp: timestamp, totals: totals, accounts: accounts)
    end

    def scan_account(account, totals, accounts)
      totals[:accounts_scanned] += 1
      models = normalized_models_hash(account.captain_models)
      return if models.blank?

      totals[:accounts_with_captain_models] += 1
      totals[:account_openrouter_configured] += 1 if Llm::Config.account_provider_available?('openrouter', account: account)

      account_report = build_account_report(account, models, totals)
      accounts << account_report
      totals[:accounts_with_changes] += 1 if account_report[:changed]
      totals[:accounts_with_unmapped] += 1 if account_report[:unmapped]
    end

    def migration_report(mode:, timestamp:, totals:, accounts:)
      {
        mode: mode,
        generated_at: timestamp.iso8601,
        totals: totals,
        accounts: accounts,
        unmapped: accounts.flat_map { |entry| entry[:changes].select { |change| change[:status] == 'unmapped' } }
      }
    end

    def each_account(scope, &)
      return scope.find_each(&) if scope.respond_to?(:find_each)

      Array(scope).each(&)
    end

    def initial_totals
      {
        accounts_scanned: 0,
        accounts_with_captain_models: 0,
        accounts_with_changes: 0,
        accounts_with_unmapped: 0,
        accounts_updated: 0,
        model_changes: 0,
        unmapped_models: 0,
        voice_models_unchanged: 0,
        direct_openai_models: 0,
        direct_anthropic_models: 0,
        direct_gemini_models: 0,
        audio_transcription_models: 0,
        moderation_models: 0,
        global_openrouter_configured: Llm::Config.installation_provider_available?('openrouter'),
        account_openrouter_configured: 0
      }
    end

    def build_account_report(account, models, totals)
      after = models.deep_dup
      changes = []

      state = { after: after, changes: changes, totals: totals }
      models.each do |feature, model_name|
        apply_model_change(account, feature, model_name, state)
      end

      enriched_changes = changes.map { |change| change.merge(account_id: account.id, account_name: account.name) }

      {
        account_id: account.id,
        account_name: account.name,
        changed: after != models,
        unmapped: enriched_changes.any? { |change| change[:status] == 'unmapped' },
        before: models,
        after: after,
        rollback: models.deep_dup,
        changes: enriched_changes
      }
    end

    def apply_model_change(account, feature, model_name, state)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return if canonical_model.blank?

      increment_inventory_counts(state[:totals], feature, canonical_model)
      change = model_change_for(account, feature, model_name, canonical_model)
      return if change.blank?

      state[:changes] << change
      state[:after][feature] = change[:to] if change[:status] == 'mapped'
      increment_change_counts(state[:totals], change)
    end

    def increment_change_counts(totals, change)
      case change[:status]
      when 'mapped'
        totals[:model_changes] += 1
      when 'unmapped'
        totals[:unmapped_models] += 1
      when 'voice_skipped'
        totals[:voice_models_unchanged] += 1
      end
    end

    def model_change_for(account, feature, model_name, canonical_model)
      return voice_skip_change(feature, model_name, canonical_model) if voice_feature?(feature)

      target_model = resolve(canonical_model, feature: feature, account: account)
      return mapped_change(feature, model_name, target_model, canonical_model) if target_model.present? && target_model != canonical_model
      return if target_model.present?

      unmapped_change(feature, model_name, canonical_model)
    end

    def voice_skip_change(feature, model_name, canonical_model)
      {
        feature: feature.to_s,
        from: model_name,
        to: model_name,
        status: 'voice_skipped',
        candidates: [canonical_model]
      }
    end

    def mapped_change(feature, model_name, target_model, canonical_model)
      {
        feature: feature.to_s,
        from: model_name,
        to: target_model,
        status: 'mapped',
        candidates: candidates_for(canonical_model)
      }
    end

    def unmapped_change(feature, model_name, canonical_model)
      {
        feature: feature.to_s,
        from: model_name,
        to: nil,
        status: 'unmapped',
        candidates: candidates_for(canonical_model)
      }
    end

    def increment_inventory_counts(totals, feature, model_name)
      totals[:audio_transcription_models] += 1 if feature.to_s == 'audio_transcription'
      totals[:moderation_models] += 1 if feature.to_s == 'moderation'
      return if voice_feature?(feature)

      totals[:direct_openai_models] += 1 if direct_openai_model_id?(model_name)
      totals[:direct_anthropic_models] += 1 if anthropic_model_id?(model_name)
      totals[:direct_gemini_models] += 1 if gemini_model_id?(model_name)
    end

    # Migration must handle legacy rows that can fail current model validations.
    # rubocop:disable Rails/SkipsModelValidations
    def update_account_models(account, models)
      settings = account.settings.to_h.deep_dup
      settings['captain_models'] = models
      account.update_columns(settings: settings, updated_at: Time.current)
    end
    # rubocop:enable Rails/SkipsModelValidations

    def normalized_models_hash(models_hash)
      models_hash.to_h.each_with_object({}) do |(feature, model_name), result|
        result[feature.to_s] = model_name.to_s
      end
    end

    def openrouter_required_for?(feature, account: nil)
      Llm::Models.openrouter_no_fallback_active_for?(feature, account: account)
    end

    def direct_openai_model_id?(model_name)
      openai_model_id?(model_name) || EXACT_MAPPINGS.key?(model_name)
    end

    def openai_model_id?(model_name)
      model_name.start_with?('gpt-')
    end

    def anthropic_model_id?(model_name)
      model_name.start_with?('claude-')
    end

    def gemini_model_id?(model_name)
      model_name.start_with?('gemini-')
    end
  end
end
# rubocop:enable Metrics/ClassLength
