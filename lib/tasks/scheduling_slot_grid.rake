namespace :scheduling do
  desc 'Find the start grid of MedElement doctors from imported receptions of the last 60 days (custom_attributes.slot_grid_min). ' \
       'Dry run; APPLY=1 stores the finer step (and removes one the data no longer needs). ACCOUNT_ID=1 limits it to one account'
  task detect_slot_grid: :environment do
    scope = Scheduling::Resource.available_for_scheduling
    scope = scope.where(account_id: ENV.fetch('ACCOUNT_ID')) if ENV['ACCOUNT_ID'].present?
    apply = ActiveModel::Type::Boolean.new.cast(ENV.fetch('APPLY', nil)) == true

    results = Scheduling::SlotGridDetector.run(scope: scope, apply: apply)
    results.each { |result| puts(result.to_h.to_json) }
    counts = results.map(&:status).tally
    puts({ applied: apply, resources: results.size, finer: counts.fetch('finer', 0), on_grid: counts.fetch('on_grid', 0),
           undecided: counts.fetch('irregular', 0) + counts.fetch('insufficient', 0) }.to_json)
  end
end
