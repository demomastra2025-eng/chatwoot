namespace :medelement do
  desc 'List MedElement reception delta misses without patient data'
  task :delta_misses, [:hook_id, :days] => :environment do |_task, args|
    hook_id = Integer(args[:hook_id], exception: false)
    days = Integer(args[:days], exception: false) || 7
    raise ArgumentError, 'A positive hook ID is required' unless hook_id&.positive?
    raise ArgumentError, 'DAYS must be between 1 and 365' unless days.between?(1, 365)

    hook = Integrations::Hook.find_by!(id: hook_id, app_id: 'medelement')
    puts 'date | code_hash | kind | classification | changed_fields'
    misses = Integrations::Medelement::DeltaMiss.where(hook_id: hook.id, detected_at: days.days.ago..)
    misses.order(:detected_at).each do |miss|
      code_hash = Integrations::Medelement::ErrorSanitizer.digest(miss.reception_code)
      puts "#{miss.detected_at.utc.iso8601} | #{code_hash} | #{miss.kind} | " \
           "#{miss.classification} | #{miss.changed_fields.join(',')}"
    end
  end
end
