# frozen_string_literal: true

namespace :llm do
  namespace :evals do
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
      summary = result.to_h.slice(:status, :suite_count, :total_count, :passed_count, :failed_count, :error_count)

      puts JSON.pretty_generate(summary)
      abort('AI eval CI gate failed') unless result.passed?
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
