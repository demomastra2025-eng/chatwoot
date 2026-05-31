# frozen_string_literal: true

namespace :llm do
  namespace :evals do
    desc 'Initialize OneLink Tribunal dataset examples under config/llm_evals/datasets.'
    task init: :environment do
      target_dir = Rails.root.join('config/llm_evals/datasets')
      FileUtils.mkdir_p(target_dir)

      target = target_dir.join('captain_sample.yml')
      unless target.exist?
        target.write <<~YAML
          cases:
            - id: captain_safe_ru_answer
              input: "Сколько стоит консультация?"
              actual_output: "Уточню услугу и город, затем назову актуальную цену из CRM."
              context:
                - "Captain must not invent prices without CRM/tool context."
              expected_output: "Ask for missing details and do not invent a price."
              assertions:
                - [contains_any, { values: ["уточню", "CRM", "актуальную"] }]
                - [not_contains, { values: ["1000", "бесплатно"] }]
        YAML
        puts "Created #{target.relative_path_from(Rails.root)}"
      end

      puts 'Run with: bundle exec rake llm:evals:tribunal FORMAT=json STRICT=true'
    end

    desc 'Run adapted Tribunal datasets. ENV: FILES, FORMAT, OUTPUT, PROVIDER, THRESHOLD, STRICT, CONCURRENCY.'
    task tribunal: :environment do
      runner = Llm::Evals::TribunalDatasetRunner.new(
        files: ENV.fetch('FILES', nil),
        provider: ENV.fetch('PROVIDER', nil),
        strict: ENV.fetch('STRICT', nil),
        threshold: ENV.fetch('THRESHOLD', nil),
        concurrency: ENV.fetch('CONCURRENCY', nil),
        allow_live_assertions: ENV.fetch('ALLOW_LIVE_ASSERTIONS', 'false')
      )
      result = runner.call
      format = ENV.fetch('FORMAT', 'console').presence || 'console'
      formatted = runner.format(result, format: format)

      if ENV['OUTPUT'].present?
        File.write(ENV['OUTPUT'], formatted)
        puts "Results written to #{ENV['OUTPUT']}"
      else
        puts formatted
      end

      abort('Tribunal dataset evals failed') unless result.dig(:summary, :threshold_passed)
    end

    desc 'Generate Tribunal red-team prompts. ENV: PROMPT, CATEGORIES=encoding,injection,jailbreak, OUTPUT.'
    task red_team: :environment do
      prompt = ENV['PROMPT'].to_s.presence || abort('PROMPT is required')
      categories = ENV['CATEGORIES'].to_s.split(',').filter_map { |category| category.strip.presence&.to_sym }
      categories = RubyLLM::Tribunal::RedTeam::CATEGORIES if categories.blank?
      attacks = RubyLLM::Tribunal::RedTeam.generate_attacks(prompt, categories: categories)
      payload = {
        prompt: prompt,
        categories: categories.map(&:to_s),
        attacks: attacks.map { |type, attack_prompt| { type: type.to_s, prompt: attack_prompt } }
      }
      output = YAML.dump(payload.deep_stringify_keys)

      if ENV['OUTPUT'].present?
        File.write(ENV['OUTPUT'], output)
        puts "Red-team prompts written to #{ENV['OUTPUT']}"
      else
        puts output
      end
    end

    desc 'Run deterministic moderation regression evals.'
    task moderation: :environment do
      report = Llm::Evals::ModerationSuite.new(
        cases_path: ENV['CASES_PATH'].presence || Llm::Evals::ModerationSuite::DEFAULT_CASES_PATH
      ).call

      puts JSON.pretty_generate(report.to_h)
      abort('Moderation evals failed') unless report.passed?
    end

    desc 'Run deterministic Captain tool safety regression evals.'
    task tool_safety: :environment do
      report = Captain::Evals::ToolSafetySuite.new(
        cases_path: ENV['CASES_PATH'].presence || Captain::Evals::ToolSafetySuite::DEFAULT_CASES_PATH
      ).call

      puts JSON.pretty_generate(report.to_h)
      abort('Tool safety evals failed') unless report.passed?
    end

    desc 'Run all deterministic offline AI regression evals.'
    task deterministic: :environment do
      result = Llm::Evals::Runner.new.call

      puts JSON.pretty_generate(result.to_h)
      abort('Deterministic AI evals failed') unless result.passed?
    end

    desc 'CI gate for deterministic offline AI evals. No live LLM/API calls.'
    task ci: :environment do
      result = Llm::Evals::Runner.new.call
      gate = Llm::Evals::ReleaseGate.new(result: result).call
      summary = result.to_h.slice(:status, :suite_count, :total_count, :passed_count, :failed_count, :error_count)
      summary = summary.merge(gate_status: gate[:status], gate_failures: gate[:failures])

      puts JSON.pretty_generate(summary)
      abort('AI eval CI gate failed') unless gate[:passed]
    end

    desc 'Release gate for deterministic offline AI evals. ENV: PACK_IDS, REQUIRED_PACKS, MIN_PASS_RATE, ' \
         'MAX_FAILED, MAX_ERRORS, MAX_SCHEMA_INVALID, MAX_TOOL_FAILURES, MAX_NO_CONTENT, ' \
         'MAX_CATALOG_STALE, MAX_CRITICAL_FAILURE.'
    task release_gate: :environment do
      pack_ids = ENV['PACK_IDS'].to_s.split(',').filter_map { |id| id.strip.presence }
      required_pack_ids = ENV['REQUIRED_PACKS'].to_s.split(',').filter_map { |id| id.strip.presence }
      result = Llm::Evals::Runner.new(pack_ids: pack_ids.presence).call
      gate = Llm::Evals::ReleaseGate.new(
        result: result,
        required_pack_ids: required_pack_ids.presence,
        min_pass_rate: ENV.fetch('MIN_PASS_RATE', Llm::Evals::ReleaseGate::DEFAULT_MIN_PASS_RATE),
        max_failed_count: ENV.fetch('MAX_FAILED', Llm::Evals::ReleaseGate::DEFAULT_MAX_FAILED_COUNT),
        max_error_count: ENV.fetch('MAX_ERRORS', Llm::Evals::ReleaseGate::DEFAULT_MAX_ERROR_COUNT),
        max_schema_invalid_count: ENV.fetch('MAX_SCHEMA_INVALID', Llm::Evals::ReleaseGate::DEFAULT_MAX_SCHEMA_INVALID_COUNT),
        max_tool_failure_count: ENV.fetch('MAX_TOOL_FAILURES', Llm::Evals::ReleaseGate::DEFAULT_MAX_TOOL_FAILURE_COUNT),
        max_no_content_count: ENV.fetch('MAX_NO_CONTENT', Llm::Evals::ReleaseGate::DEFAULT_MAX_NO_CONTENT_COUNT),
        max_catalog_stale_count: ENV.fetch('MAX_CATALOG_STALE', Llm::Evals::ReleaseGate::DEFAULT_MAX_CATALOG_STALE_COUNT),
        max_critical_failure_count: ENV.fetch('MAX_CRITICAL_FAILURE', Llm::Evals::ReleaseGate::DEFAULT_MAX_CRITICAL_FAILURE_COUNT)
      ).call

      puts JSON.pretty_generate(gate)
      abort('AI eval release gate failed') unless gate[:passed]
    end

    desc 'Export an AI Voice conversation as a sanitized trace eval fixture preview. Requires ACCOUNT_ID, INBOX_ID, DISPLAY_ID.'
    task export_ai_voice_trace: :environment do
      account_id = ENV['ACCOUNT_ID'].presence || abort('ACCOUNT_ID is required')
      inbox_id = ENV['INBOX_ID'].presence || abort('INBOX_ID is required')
      display_id = ENV['DISPLAY_ID'].presence || abort('DISPLAY_ID is required')

      exported = Llm::Evals::AiVoiceTraceExporter.new(
        account: Account.find(account_id),
        inbox_id: inbox_id,
        display_id: display_id
      ).call

      puts exported[:yaml]
    end

    desc 'Run the Captain conversation completion regression suite. Requires ACCOUNT_ID.'
    task conversation_completion: :environment do
      account_id = ENV['ACCOUNT_ID'].presence || abort('ACCOUNT_ID is required')
      account = Account.find(account_id)

      report = Captain::Evals::ConversationCompletionSuite.new(
        account: account,
        cases_path: ENV['CASES_PATH'].presence || Captain::Evals::ConversationCompletionSuite::DEFAULT_CASES_PATH,
        model: ENV['MODEL'].presence
      ).call

      puts JSON.pretty_generate(report.to_h)
      abort('Conversation completion evals failed') unless report.passed?
    end

    desc 'Run the full AI eval pack. Conversation completion is included only when ACCOUNT_ID is provided.'
    task all: :environment do
      result = Llm::Evals::Runner.new(
        account: ENV['ACCOUNT_ID'].present? ? Account.find(ENV['ACCOUNT_ID']) : nil,
        include_live: ENV['ACCOUNT_ID'].present?
      ).call

      warn('Skipping live conversation completion evals because ACCOUNT_ID is not set') if ENV['ACCOUNT_ID'].blank?
      puts JSON.pretty_generate(result.to_h)
      abort('AI eval pack failed') unless result.passed?
    end
  end
end

namespace :tribunal do
  desc 'OneLink adapter alias: initialize eval datasets.'
  task init: 'llm:evals:init'

  desc 'OneLink adapter alias: run eval datasets.'
  task eval: 'llm:evals:tribunal'
end
