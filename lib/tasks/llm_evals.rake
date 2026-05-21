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
