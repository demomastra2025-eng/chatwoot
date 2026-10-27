# frozen_string_literal: true

namespace :onelink do
  namespace :threads do
    desc 'Delete the activity lines "Объединено: звонок из канала «…»" / "Объединено: диалог из канала «…»" (and their English and ' \
         'Kazakh texts) that the one-dialog merge used to write into the conversations. The merge itself is not touched. Dry run by ' \
         'default: counts per account, nothing is written. APPLY=1 CONFIRM=yes BACKUP_DIR=<dir> writes the backup ' \
         'merge_lines_backup_<time>.json into BACKUP_DIR (every column of every line; a persistent directory, not tmp) and reads it ' \
         'back, then deletes the lines in one transaction. RESTORE=<backup file> puts the lines back with their ids (a dry run ' \
         'unless APPLY=1 CONFIRM=yes too). Repeat the dry run after the delete: it must find 0. ' \
         'Usage: rake onelink:threads:delete_merge_lines [APPLY=1 CONFIRM=yes BACKUP_DIR=dir] or RESTORE=file [APPLY=1 CONFIRM=yes]'
    task delete_merge_lines: :environment do
      apply = ENV.fetch('APPLY', '').strip
      abort("REFUSED: APPLY must be 1 or 0, not #{apply.inspect}") unless ['', '0', '1'].include?(apply)
      abort('REFUSED: APPLY=1 needs CONFIRM=yes') if apply == '1' && ENV.fetch('CONFIRM', '').strip != 'yes'

      cleanup = CommunicationThreads::MergeLinesCleanup.new
      restore = ENV.fetch('RESTORE', '').strip
      if restore.present?
        cleanup.restore(restore, apply: apply == '1')
      elsif apply == '1'
        cleanup.delete(backup_dir: ENV.fetch('BACKUP_DIR', '').strip)
      else
        cleanup.report
      end
    rescue CommunicationThreads::MergeLinesCleanup::Refused => e
      abort("REFUSED: #{e.message}")
    end
  end
end
