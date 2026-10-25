namespace :onelink do
  namespace :captain do
    desc 'Apply the prompt pack of one clinic (a prompts-v2 JSON file: the clinic block and the prompt and card of every listed ' \
         'agent), or roll one back from its backup. Dry run by default: the sha256 of the file, what changes with the lengths in ' \
         'characters (VERBOSE=1 adds a diff of the texts) and the digest of the change. APPLY=1 CONFIRM=<that digest> writes exactly ' \
         'that change: it backs the stored texts up to tmp/prompt_pack_backup_<account>_<timestamp>.json (BACKUP_DIR=dir to put it ' \
         'elsewhere), then writes in one transaction, and refuses when the file or a stored text changed since the dry run; nothing ' \
         'to change writes nothing. A pack needs a build with the decision router. Usage: rake onelink:captain:apply_prompt_pack ' \
         'FILE=pack.json [VERBOSE=1] [APPLY=1 CONFIRM=digest], or RESTORE=backup.json [APPLY=1 CONFIRM=digest]'
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
      confirm = ENV.fetch('CONFIRM', '').strip.presence
      pack = Captain::PromptPack.new(verbose: switch.call('VERBOSE'),
                                     backup_dir: ENV.fetch('BACKUP_DIR', '').strip.presence || Rails.root.join('tmp'))
      backup.present? ? pack.restore(backup, apply: apply, confirm: confirm) : pack.apply_file(file, apply: apply, confirm: confirm)
    rescue Captain::PromptPack::Refused => e
      abort("REFUSED, nothing was written:\n#{e.message}")
    end
  end
end
