if defined?(HairTrigger::MigrationReader)
  migration_reader = HairTrigger::MigrationReader.singleton_class

  unless migration_reader.method_defined?(:get_triggers_without_onelink_init_schema_skip)
    migration_reader.class_eval do
      alias_method :get_triggers_without_onelink_init_schema_skip, :get_triggers

      def get_triggers(source, options)
        return [] if skip_onelink_init_schema?(source)

        get_triggers_without_onelink_init_schema_skip(source, options)
      end

      private

      # HairTrigger parses every applied migration to reconstruct trigger
      # history. Under Ruby 3.4, ruby_parser times out on our squashed
      # init_schema migration, while the same trigger definitions are already
      # present in db/schema.rb and get loaded through previous_schema.
      def skip_onelink_init_schema?(source)
        return false unless source.respond_to?(:filename)
        return false unless File.basename(source.filename) == '20230426130150_init_schema.rb'

        File.exist?(HairTrigger.schema_rb_path)
      end
    end
  end
end
