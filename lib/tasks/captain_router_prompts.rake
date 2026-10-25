# The agent prompts for the decision router: the router decides who answers each patient turn, so no agent prompt may describe
# transfers, other agents or a coordinator role (see config/captain/router_prompt_migration/ and Captain::PromptMigration).
#
#   rake captain:router_prompts:migrate [FILE=...] [ACCOUNT_IDS=43,74] [INCLUDE_INTERNAL=1]   # DRY RUN (default): diffs and lint
#   rake captain:router_prompts:migrate APPLY=1 CONFIRM=<plan digest> [FILE=...]            # writes what the dry run showed
#   rake captain:router_prompts:rollback MIGRATION=2026-10-router [APPLY=1 CONFIRM=<digest>]
#
# Release order: the owner approves the dry run computed on PROD, APPLY=1 runs right before the code deploy, the dry run runs once
# more after it. A drift (a stored text changed after the review) or a lint error makes the exit code non-zero; an agent whose
# proposed texts still have a lint error is never written (LINT_ERROR in the report).
# rubocop:disable Metrics/BlockLength
namespace :captain do
  namespace :router_prompts do
    default_file = Rails.root.join('config/captain/router_prompt_migration/2026-10-router.yml').to_s
    account_ids = -> { ENV.fetch('ACCOUNT_IDS', '').split(',').map(&:strip).compact_blank.map(&:to_i) }

    desc 'Prompt migration for the decision router: dry run by default (per-assistant diffs and lint); APPLY=1 CONFIRM=<digest> writes'
    task migrate: :environment do
      plan = Captain::PromptMigration::Plan.new(file: ENV.fetch('FILE', default_file), account_ids: account_ids.call,
                                                include_internal: ENV['INCLUDE_INTERNAL'] == '1')
      puts Captain::PromptMigration::Report.new(plan)

      if ENV['APPLY'] == '1'
        outcome = Captain::PromptMigration::Applier.new(plan, confirm: ENV.fetch('CONFIRM', nil)).apply!
        puts "\nApplied: #{outcome.applied.size} (#{outcome.applied.join(', ')}); skipped: #{outcome.skipped.size} " \
             "(#{outcome.skipped.join(', ')}); drift: #{plan.drift_count}; blocked by lint errors: #{plan.blocked_count}"
        exit(1) if outcome.skipped.any? || plan.drift_count.positive? || plan.error_count.positive?
      else
        puts "\nDRY RUN - nothing written. To apply: APPLY=1 CONFIRM=#{plan.digest}"
        exit(1) if plan.drift_count.positive? || plan.error_count.positive?
      end
    end

    desc 'Roll a prompt migration back from the saved prompt history: dry run by default; APPLY=1 CONFIRM=<digest> writes'
    task rollback: :environment do
      rollback = Captain::PromptMigration::Rollback.new(migration: ENV.fetch('MIGRATION') { abort 'MIGRATION=<name> is required' },
                                                        account_ids: account_ids.call)
      rollback.entries.each do |entry|
        puts "== account #{entry.account_id} / assistant #{entry.assistant_id} #{entry.name}"
        puts Captain::PromptMigration::TextDiff.unified(entry.current[:description], entry.proposed[:description], label: 'description')
        puts Captain::PromptMigration::TextDiff.unified(entry.current[:routing_description], entry.proposed[:routing_description],
                                                        label: 'routing_description')
      end
      if ENV['APPLY'] == '1'
        restored = rollback.apply!(confirm: ENV.fetch('CONFIRM', nil))
        puts "\nRestored: #{restored.size} (#{restored.join(', ')}) of #{rollback.entries.size}"
        exit(1) if restored.size != rollback.entries.size
      else
        puts "\nDRY RUN - nothing written. #{rollback.entries.size} agents. To apply: APPLY=1 CONFIRM=#{rollback.digest}"
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
