# The platform embedding model and the full re-embedding that a change of it needs, see Captain::Llm::EmbeddingReindexService.
#
#   rake onelink:embeddings:status                                   # which model made the vectors of each table; fails if a row has no
#                                                                    # current vector of the model in force
#   rake onelink:embeddings:preview MODEL=google/gemini-embedding-001  # dry run: counts, characters, requests; calls no model, writes nothing
#   rake onelink:embeddings:apply MODEL=google/gemini-embedding-001 BACKUP_DIR=/path CONFIRM=yes
#                                                                    # backup, re-embed everything, switch the model (one transaction),
#                                                                    # embed again what changed meanwhile; MAX_TOKENS=... raises the cost cap
#   rake onelink:embeddings:refresh CONFIRM=yes                      # embed again the rows without a current vector of the model in force
#   rake onelink:embeddings:restore BACKUP_DIR=/path CONFIRM=yes     # put the old vectors and the old setting back
#
# Without CONFIRM=yes `apply` and `restore` only show what they would do. BACKUP_DIR of `apply` defaults to
# storage/onelink_backups/embeddings-<UTC time> (the persistent volume of the production containers); it must not exist yet.
# rubocop:disable Metrics/BlockLength
namespace :onelink do
  namespace :embeddings do
    def embeddings_print_plan(plan)
      switch = plan[:switches_model] ? ', the apply switches it' : ''
      puts "Model: #{plan[:model]} (now in force: #{plan[:current_model] || 'built-in default'}#{switch})"
      plan[:sources].each do |key, item|
        puts format('  %-9<key>s rows %<rows>5d  chars %<chars>8d  accounts %<accounts>3d  requests %<requests>3d  vectors now %<now>5d',
                    key: key, rows: item[:rows], chars: item[:chars], accounts: item[:accounts], requests: item[:requests],
                    now: item[:with_vector_now])
      end
      puts "Total: #{plan[:rows]} rows, #{plan[:chars]} characters (about #{plan[:estimated_tokens]} tokens, cap #{plan[:max_tokens]}), " \
           "#{plan[:requests]} requests."
      puts "Service search threshold (service_min_score) for the model: #{plan[:calibrated] ? 'calibrated' : 'MISSING (apply would refuse)'}"
      puts "OpenRouter key: #{plan[:key_configured] ? 'configured' : 'MISSING (apply would stop at once)'}"
    end

    def embeddings_print_status(status)
      status.each do |key, item|
        models = item[:vectors_by_model].map { |name, count| "#{name}: #{count}" }.join(', ').presence || 'no vectors'
        wrong = item[:wrong_size].positive? ? "  WRONG SIZE: #{item[:wrong_size]}" : ''
        stale = item[:stale].positive? ? "  NO CURRENT VECTOR: #{item[:stale]}" : ''
        puts format('  %-9<key>s rows %<rows>5d  %<models>s%<wrong>s%<stale>s',
                    key: key, rows: item[:rows], models: models, wrong: wrong, stale: stale)
      end
    end

    desc 'Which embedding model made the vectors of each table'
    task status: :environment do
      puts "CAPTAIN_EMBEDDING_MODEL: #{Captain::Llm::EmbeddingService.configured_embedding_model || '(not set: built-in default)'}"
      service = Captain::Llm::EmbeddingReindexService.new
      status = service.status
      embeddings_print_status(status)
      abort 'Not consistent: some rows have no current vector of the model in force, or a vector of a wrong size.' unless service.consistent?(status)

      puts 'Consistent: every row has a current vector of the model in force.'
    end

    desc 'Dry run of the re-embedding: counts, characters and requests (MODEL=...); calls no model and writes nothing'
    task preview: :environment do
      embeddings_print_plan(Captain::Llm::EmbeddingReindexService.new(model: ENV.fetch('MODEL', nil)).preview)
    end

    desc 'Back up the old vectors, re-embed everything with MODEL=... and switch CAPTAIN_EMBEDDING_MODEL; needs CONFIRM=yes'
    task apply: :environment do
      model = ENV.fetch('MODEL') { abort 'MODEL=provider/model is required' }
      backup_dir = ENV.fetch('BACKUP_DIR') { Rails.root.join('storage/onelink_backups', "embeddings-#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}").to_s }
      service = Captain::Llm::EmbeddingReindexService.new(
        model: model, backup_dir: backup_dir,
        max_tokens: ENV.fetch('MAX_TOKENS', Captain::Llm::EmbeddingReindexService::MAX_ESTIMATED_TOKENS)
      )
      embeddings_print_plan(service.preview)
      abort "BACKUP_DIR #{backup_dir} already exists" if File.exist?(backup_dir)

      if ENV['CONFIRM'] == 'yes'
        begin
          result = service.apply!
        rescue Captain::Llm::EmbeddingReindexService::Error => e
          abort "Stopped: #{e.message}"
        end
        puts "Done. Backup: #{backup_dir}"
        embeddings_print_status(result['status'])
      else
        puts "\nDry run, nothing changed. Backup would go to #{backup_dir}. Run again with CONFIRM=yes to apply."
      end
    end

    desc 'Embed again the rows that have no current vector of the model in force (no backup, no switch); needs CONFIRM=yes'
    task refresh: :environment do
      service = Captain::Llm::EmbeddingReindexService.new
      status = service.status
      embeddings_print_status(status)
      stale = status.values.sum { |item| item[:stale] }
      if ENV['CONFIRM'] == 'yes'
        begin
          found = service.refresh!
        rescue Captain::Llm::EmbeddingReindexService::Error => e
          abort "Stopped: #{e.message}"
        end
        puts "Embedded again: #{found} rows."
        embeddings_print_status(service.status)
      else
        puts "
Dry run, nothing changed: #{stale} rows would be embedded again. Run again with CONFIRM=yes."
      end
    end

    desc 'Put the old vectors and the old CAPTAIN_EMBEDDING_MODEL back from BACKUP_DIR=...; needs CONFIRM=yes'
    task restore: :environment do
      backup_dir = ENV.fetch('BACKUP_DIR') { abort 'BACKUP_DIR=/path/of/the/backup is required' }
      service = Captain::Llm::EmbeddingReindexService.new(backup_dir: backup_dir)
      manifest = Captain::Llm::EmbeddingBackup.new(backup_dir).read_manifest
      puts "Backup of #{manifest['created_at']}: #{manifest['files'].map { |key, info| "#{key} #{info['rows']}" }.join(', ')}; " \
           "the setting was #{manifest.dig('previous_setting', 'exists') ? manifest.dig('previous_setting', 'value').inspect : 'not set'}."

      if ENV['CONFIRM'] == 'yes'
        service.restore!
        puts 'Restored.'
        embeddings_print_status(service.status)
      else
        puts "\nDry run, nothing changed. Run again with CONFIRM=yes to restore."
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
