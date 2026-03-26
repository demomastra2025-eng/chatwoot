# This rake task was added by annotate_rb gem.
# Set ANNOTATERB_SKIP_ON_DB_TASKS=1 to skip automatic annotation on db tasks.
if Rails.env.development? && ENV['ANNOTATERB_SKIP_ON_DB_TASKS'].nil?
  require 'annotate_rb'

  AnnotateRb::Core.load_rake_tasks
end
