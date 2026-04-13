# frozen_string_literal: true

namespace :llm do
  desc 'Run the combined AI release check for one account. Requires ACCOUNT_ID.'
  task release_check: :environment do
    account_id = ENV['ACCOUNT_ID'].presence || abort('ACCOUNT_ID is required')
    account = Account.find(account_id)
    filters = {
      feature: ENV['FEATURE'].presence,
      model: ENV['MODEL'].presence,
      runtime_mode: ENV['RUNTIME_MODE'].presence,
      assistant_id: ENV['ASSISTANT_ID'].presence
    }.compact
    date_range = begin
      since = ENV['SINCE'].present? ? Time.zone.parse(ENV['SINCE']) : nil
      until_at = ENV['UNTIL'].present? ? Time.zone.parse(ENV['UNTIL']) : nil
      since && until_at ? (since..until_at) : nil
    rescue ArgumentError
      abort('SINCE and UNTIL must be valid time values')
    end

    report = Llm::ReleaseCheck::Runner.new(
      account: account,
      date_range: date_range,
      filters: filters,
      evaluation_model: ENV['EVAL_MODEL'].presence,
      include_live_evals: true
    ).call

    puts JSON.pretty_generate(report.to_h)
    abort('AI release check failed') unless report.passed?
  end
end
