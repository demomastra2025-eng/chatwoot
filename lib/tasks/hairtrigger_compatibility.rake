# Rails 7.2 already dumps through a connection pool and HairTrigger's SchemaDumper.
# HairTrigger 1.0.0 appends a second dump with an adapter where Rails expects a pool.
hairtrigger_dump_task = File.join(Gem.loaded_specs.fetch('hairtrigger').full_gem_path, 'lib/tasks/hair_trigger.rake')
Rake::Task['db:schema:dump'].actions.reject! do |action|
  action.source_location.first == hairtrigger_dump_task
end
