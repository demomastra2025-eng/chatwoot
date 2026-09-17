# frozen_string_literal: true

require 'json'

results = {}

begin
  conversation_policy_normalizer = 'Inboxes::ConversationPolicyNormalizer'.constantize
rescue NameError
  migration = Rails.root.join('db/migrate/20260901060514_normalize_inbox_conversation_policy.rb')
  raise 'conversation policy normalizer is missing from this release' if migration.exist?

  results[:conversation_policy] = { status: 'skipped', reason: 'release_not_present' }
else
  result = conversation_policy_normalizer.perform
  raise 'conversation policy normalization left mismatches' unless result[:mismatches_after].zero?

  results[:conversation_policy] = result.merge(status: 'ok')
end

resource_timezone_normalizer = 'Scheduling::ResourceTimezoneNormalizer'.safe_constantize
if resource_timezone_normalizer.nil?
  results[:resource_timezones] = { status: 'skipped', reason: 'release_not_present' }
else
  result = resource_timezone_normalizer.perform
  raise 'resource timezone normalization left mismatches' unless result[:mismatches_after].zero?

  results[:resource_timezones] = result.merge(status: 'ok')
end

puts JSON.generate(status: 'ok', finalizers: results)
