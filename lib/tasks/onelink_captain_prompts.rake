# Replaced by onelink:captain:apply_prompt_pack (lib/tasks/onelink_captain_prompt_pack.rake), which backs the stored texts up
# first and writes only the change of the reviewed dry run. The old name stays for one release so that a runbook or a habit that
# still calls it gets the new command instead of a write without a backup.
namespace :onelink do
  namespace :captain do
    desc 'Replaced by onelink:captain:apply_prompt_pack: writes nothing and prints the command to use instead'
    task :apply_prompts_v2, %i[json_path apply] => :environment do |_task, args|
      file = args[:json_path].to_s.strip.presence || '<pack.json>'
      abort("REFUSED, nothing was written: onelink:captain:apply_prompts_v2 was replaced by onelink:captain:apply_prompt_pack.\n" \
            "Dry run: rake onelink:captain:apply_prompt_pack FILE=#{file}\n" \
            'Then, to write what it showed: the same with APPLY=1 CONFIRM=<the digest that the dry run printed>')
    end
  end
end
