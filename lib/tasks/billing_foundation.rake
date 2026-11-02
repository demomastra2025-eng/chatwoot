# frozen_string_literal: true

namespace :billing do
  namespace :foundation do
    desc 'Read-only foundation readiness; no bootstrap, migration or activation'
    task preflight: :environment do
      report = Billing::FoundationPreflight.report
      puts JSON.pretty_generate(report)
      abort 'Billing foundation is not ready; no records changed.' unless report[:ready]
    end
  end
end
