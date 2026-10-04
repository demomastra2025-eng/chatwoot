if defined?(HairTrigger) && ActiveRecord::Tasks::DatabaseTasks.respond_to?(:migration_connection_pool)
  hair_trigger = HairTrigger.singleton_class

  unless hair_trigger.method_defined?(:migrator_with_rails_migration_context)
    hair_trigger.class_eval do
      def migrator_with_rails_migration_context
        context = ActiveRecord::Tasks::DatabaseTasks.migration_connection_pool.migration_context
        ActiveRecord::Migrator.new(:up, context.migrations, context.schema_migration, context.internal_metadata)
      end

      alias_method :migrator, :migrator_with_rails_migration_context
    end
  end
end

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

if defined?(HairTrigger)
  require 'active_record/schema_dumper'

  module HairTrigger::Rails72SchemaDumperPoolCompatibility
    def dump(pool = ActiveRecord::Base.connection_pool, stream = $stdout, config = ActiveRecord::Base)
      pool = pool.pool unless pool.respond_to?(:with_connection)
      super(pool, stream, config)
    end
  end

  schema_dumper = ActiveRecord::SchemaDumper.singleton_class
  unless schema_dumper.ancestors.include?(HairTrigger::Rails72SchemaDumperPoolCompatibility)
    schema_dumper.prepend(HairTrigger::Rails72SchemaDumperPoolCompatibility)
  end
end
