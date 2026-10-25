namespace :onelink do
  namespace :captain do
    desc 'Apply the prompt pack of one clinic (a prompts-v2 JSON file: the clinic block and the prompt and card of every listed ' \
         'agent), or roll one back from its backup. Dry run by default: what changes and the lengths in characters (VERBOSE=1 ' \
         'adds a diff of the texts). APPLY=1 backs the stored texts up to tmp/prompt_pack_backup_<account>_<timestamp>.json ' \
         '(BACKUP_DIR=dir to put it elsewhere), then writes in one transaction; nothing to change writes nothing. Usage: rake ' \
         'onelink:captain:apply_prompt_pack FILE=pack.json [APPLY=1] [VERBOSE=1], or RESTORE=backup.json [APPLY=1]'
    task apply_prompt_pack: :environment do
      switch = lambda do |name|
        value = ENV.fetch(name, '').strip
        abort("REFUSED: #{name} must be 1 or 0, not #{value.inspect}") unless ['', '0', '1'].include?(value)
        value == '1'
      end
      file = ENV.fetch('FILE', '').strip
      backup = ENV.fetch('RESTORE', '').strip
      abort('REFUSED: pass exactly one of FILE=<pack.json> and RESTORE=<backup.json>') if file.present? == backup.present?

      apply = switch.call('APPLY')
      pack = Captain::PromptPack.new(verbose: switch.call('VERBOSE'),
                                     backup_dir: ENV.fetch('BACKUP_DIR', '').strip.presence || Rails.root.join('tmp'))
      backup.present? ? pack.restore(backup, apply: apply) : pack.apply_file(file, apply: apply)
    rescue Captain::PromptPack::Refused => e
      abort("REFUSED, nothing was written:\n#{e.message}")
    end
  end
end
