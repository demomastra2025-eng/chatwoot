def captain_capability_plans
  scope = Captain::Assistant.order(:id)
  scope = scope.where(account_id: ENV.fetch('ACCOUNT_ID')) if ENV['ACCOUNT_ID'].present?
  scope.map { |assistant| Captain::ToolAccessMigrationPlan.for(assistant) }
end

namespace :captain do
  namespace :capabilities do
    desc 'Read-only migration plans, including blockers, dormant tools and source digests'
    task plan: :environment do
      puts JSON.generate(captain_capability_plans)
    end

    desc 'Release gate: every persisted assistant must have a valid canonical capability contract'
    task preflight: :environment do
      plans = captain_capability_plans
      pending = plans.reject { |plan| plan[:status] == 'migrated' && plan[:blockers].empty? }
      invalid = Captain::Assistant.where(id: plans.pluck(:assistant_id)).reject do |assistant|
        !Captain::Capabilities.configured?(assistant.config) || Captain::Capabilities.valid?(assistant.config['capabilities'])
      end
      puts JSON.generate(total: plans.length, pending: pending, invalid_assistant_ids: invalid.map(&:id))
      abort 'Capability cutover is incomplete' if pending.any? || invalid.any?
    end

    desc 'Explicit single-assistant activation; dry-run unless CONFIRM=yes, requires ACTOR_ID and SOURCE_DIGEST'
    task activate: :environment do
      assistant = Captain::Assistant.find(ENV.fetch('ASSISTANT_ID'))
      if ENV['CONFIRM'] != 'yes'
        puts JSON.generate(Captain::ToolAccessMigrationPlan.for(assistant))
        next
      end
      service = Captain::CapabilitiesMigrationService.new(assistant: assistant, actor: SuperAdmin.find(ENV.fetch('ACTOR_ID')))
      service.activate!(expected_digest: ENV.fetch('SOURCE_DIGEST'))
      puts JSON.generate(assistant_id: assistant.id, status: 'migrated')
    end
  end
end
