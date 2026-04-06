namespace :llm do
  namespace :models do
    desc 'Refresh the in-memory RubyLLM model registry. Usage: rake llm:models:refresh[remote_only]'
    task :refresh, [:remote_only] => :environment do |_, args|
      remote_only = args[:remote_only]
      remote_only = remote_only.nil? ? true : ActiveModel::Type::Boolean.new.cast(remote_only)

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
end
