require 'json'

namespace :conversations do
  namespace :identity do
    desc 'Read-only audit of duplicate non-email Conversation identities. Optional ACCOUNT_ID and LIMIT.'
    task audit: :environment do
      report = Conversations::IdentityAudit.new(
        account_id: ENV.fetch('ACCOUNT_ID', nil),
        limit: ENV.fetch('LIMIT', Conversations::IdentityAudit::DEFAULT_LIMIT)
      ).perform

      puts JSON.pretty_generate(report)
    end
  end
end
