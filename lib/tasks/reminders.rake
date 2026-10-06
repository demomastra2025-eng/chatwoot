namespace :reminders do
  desc 'Preview legacy automation plan conversion; set APPLY=1 to update rules'
  task convert_plan_actions: :environment do
    Reminders::ConvertPlanActionsService.new(apply: ENV['APPLY'] == '1').perform
  end
end
