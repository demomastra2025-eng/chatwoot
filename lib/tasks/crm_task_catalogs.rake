namespace :crm do
  namespace :task_catalogs do
    desc 'Rename task types, outcomes and statuses that still carry the seeded English names (including "Touch") ' \
         'to the neutral names of the account language. Repeatable; names edited by an admin are never touched.'
    task localize_names: :environment do
      renamed = Crm::TaskCatalogs::NameRepair.new(lock_timeout: '3s').perform
      puts "Renamed #{renamed} task catalog rows"
    end
  end
end
