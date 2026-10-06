# The reviewed Luna 6 cut-over, see script/onelink/LUNA_CUTOVER_RUNBOOK.md and Llm::CaptainLunaRollout.
#
#   rake llm:luna_cutover:preview SNAPSHOT=/safe/place/luna6.json            # changes no data; writes the 0600 snapshot
#   rake llm:luna_cutover:apply SNAPSHOT=/safe/place/luna6.json CONFIRM=yes   # without CONFIRM=yes it only shows the plan
#   rake llm:luna_cutover:rollback SNAPSHOT=/safe/place/luna6.json CONFIRM=yes
# rubocop:disable Metrics/BlockLength
namespace :llm do
  namespace :luna_cutover do
    desc 'Dry-run preview of the Luna 6 cut-over; SNAPSHOT=/path also writes the rollback snapshot (mode 0600). Changes no data.'
    task preview: :environment do
      plan = Llm::CaptainLunaRollout.plan
      puts Llm::CaptainLunaRollout::Preview.new(plan, target: Llm::CaptainLunaRollout::TARGET_MODEL)

      path = ENV.fetch('SNAPSHOT', nil)
      if path.blank?
        puts "\nNo snapshot written. Add SNAPSHOT=/path/to/file.json to write the rollback snapshot."
      else
        Llm::CaptainLunaRollout::Snapshot.write(plan, path)
        puts "\nSnapshot written and verified (mode 0600): #{path}"
      end
    end

    desc 'Apply the Luna 6 cut-over from SNAPSHOT=/path; needs CONFIRM=yes, otherwise it only shows what it would do'
    task apply: :environment do
      snapshot = Llm::CaptainLunaRollout::Snapshot.read(ENV.fetch('SNAPSHOT') { abort 'SNAPSHOT=/path/to/file.json is required' })
      puts Llm::CaptainLunaRollout::Preview.new(snapshot, target: Llm::CaptainLunaRollout::TARGET_MODEL)

      if ENV['CONFIRM'] == 'yes'
        changed = Llm::CaptainLunaRollout.apply!(snapshot)
        puts "\nApplied: #{changed} accounts changed. Keep the snapshot for the rollback."
      else
        puts "\nDry run, nothing changed. Run again with CONFIRM=yes to apply."
      end
    end

    desc 'Roll the Luna 6 cut-over back from SNAPSHOT=/path; needs CONFIRM=yes, otherwise it only shows what it would do'
    task rollback: :environment do
      snapshot = Llm::CaptainLunaRollout::Snapshot.read(ENV.fetch('SNAPSHOT') { abort 'SNAPSHOT=/path/to/file.json is required' })
      puts Llm::CaptainLunaRollout::Preview.new(snapshot, target: Llm::CaptainLunaRollout::TARGET_MODEL)

      if ENV['CONFIRM'] == 'yes'
        restored = Llm::CaptainLunaRollout.rollback!(snapshot)
        puts "\nRolled back: #{restored} accounts restored."
        differences = Llm::CaptainLunaRollout.restored_differences(snapshot)
        puts(differences.empty? ? 'Installation rows and effective models are as in the snapshot.' : "Differences:\n  #{differences.join("\n  ")}")
      else
        puts "\nDry run, nothing changed. Run again with CONFIRM=yes to roll back."
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
