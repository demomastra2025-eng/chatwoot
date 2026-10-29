# frozen_string_literal: true

# Restores missing `content` and `additional_attributes['template_buttons']` on outgoing WhatsApp
# template messages whose `content` was saved blank (`""` or `NULL`).
#
# Usage:
#   # 1. Dry-run (read-only, prints aggregate counts only вЂ” zero PII):
#   bundle exec rails runner script/onelink/backfill_blank_whatsapp_template_messages.rb
#
#   # 2. Apply with pre-change JSON backup:
#   APPLY=1 BACKUP_FILE=/app/storage/onelink_backups/wa-blank-tpl-20261029.json \
#     bundle exec rails runner script/onelink/backfill_blank_whatsapp_template_messages.rb
#
#   # 3. Rollback from backup file:
#   RESTORE_FILE=/app/storage/onelink_backups/wa-blank-tpl-20261029.json APPLY=1 \
#     bundle exec rails runner script/onelink/backfill_blank_whatsapp_template_messages.rb

result = Whatsapp::BlankTemplateMessagesBackfill.new(
  apply: ENV['APPLY'] == '1',
  backup_file: ENV.fetch('BACKUP_FILE', nil),
  restore_file: ENV.fetch('RESTORE_FILE', nil),
  account_id: ENV.fetch('ACCOUNT_ID', nil)
).perform

puts result.to_json
