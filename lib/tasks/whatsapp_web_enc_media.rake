namespace :whatsapp_web do
  desc 'Restore historical WhatsApp Web .enc attachments in-place (DRY_RUN=1 by default; pass APPLY=1 to mutate)'
  task restore_enc_attachments: :environment do
    bool_type = ActiveModel::Type::Boolean.new
    apply_requested = bool_type.cast(ENV.fetch('APPLY', nil)) == true
    dry_run_forced = ENV.key?('DRY_RUN') && bool_type.cast(ENV.fetch('DRY_RUN', nil)) == true
    apply_mode = apply_requested && !dry_run_forced

    result = WhatsappWeb::EncAttachmentRestorationService.new(
      apply: apply_mode,
      attachment_ids: ENV.fetch('ATTACHMENT_IDS', nil),
      backup_dir: ENV.fetch('BACKUP_DIR', nil),
      evolution_database_url: ENV.fetch('EVOLUTION_DATABASE_URL', nil)
    ).perform

    puts JSON.pretty_generate(result.as_json)
  end
end
