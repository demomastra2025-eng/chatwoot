# rubocop:disable Metrics/BlockLength
namespace :llm do
  namespace :models do
    desc 'Refresh the in-memory RubyLLM model registry. Usage: rake llm:models:refresh[remote_only]'
    task :refresh, [:remote_only] => :environment do |_, args|
      remote_only = args[:remote_only]
      remote_only = remote_only.nil? || ActiveModel::Type::Boolean.new.cast(remote_only)

      metadata = Llm::ModelRegistryService.refresh!(remote_only: remote_only)

      puts "Refreshed RubyLLM registry at #{metadata[:last_refreshed_at]}"
      puts "Total runtime models: #{metadata[:total_models]}"
      puts "Chat models: #{metadata[:chat_models]}"
      puts "Configured product models: #{metadata[:configured_models]}"
      puts "Resolved configured models: #{metadata[:resolved_models]}"
      puts "Remote only: #{metadata[:remote_only]}"
    end

    desc 'Audit configured LLM models and defaults against RubyLLM registry'
    task audit: :environment do
      result = Llm::ModelRegistryService.audit_configuration

      puts "LLM configuration valid: #{result[:valid]}"

      if result[:warnings].any?
        puts "\nWarnings:"
        result[:warnings].each { |warning| puts "- #{warning}" }
      end

      if result[:errors].any?
        puts "\nErrors:"
        result[:errors].each { |error| puts "- #{error}" }
        abort("\nLLM configuration audit failed.")
      end

      puts "\nLLM configuration audit passed."
    end
  end

  namespace :openrouter do
    namespace :model_migration do
      desc 'Dry-run migration of stored Captain model IDs to OpenRouter equivalents and write a JSON report under logs/'
      task dry_run: :environment do
        report = Llm::OpenRouterModelMigration.dry_run
        path = Llm::OpenRouterModelMigration.write_report(report)

        puts JSON.pretty_generate(report[:totals])
        puts "Report: #{path}"
      end

      desc 'Apply stored Captain model ID migration to OpenRouter equivalents. Set ALLOW_UNMAPPED=true to continue despite unresolved entries.'
      task apply: :environment do
        allow_unmapped = ActiveModel::Type::Boolean.new.cast(ENV.fetch('ALLOW_UNMAPPED', nil))
        report = Llm::OpenRouterModelMigration.apply!(allow_unmapped: allow_unmapped)
        path = Llm::OpenRouterModelMigration.write_report(report)

        puts JSON.pretty_generate(report[:totals])
        puts "Report: #{path}"
      rescue Llm::OpenRouterModelMigration::UnmappedModelsError => e
        abort("OpenRouter model migration blocked: #{e.message}. Run llm:openrouter:model_migration:dry_run and review the report.")
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
