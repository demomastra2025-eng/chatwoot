namespace :medelement do
  desc 'Report (default) or repair owned appointments whose chat contact holds the separate patient code. ' \
       'Usage: rake medelement:repair_patient_cards [ACCOUNT_ID=1] [APPLY=1]'
  task repair_patient_cards: :environment do
    apply = ENV['APPLY'] == '1'
    accounts = ENV['ACCOUNT_ID'].present? ? Account.where(id: ENV['ACCOUNT_ID']) : Account.all
    accounts.find_each do |account|
      report = Integrations::Medelement::PatientCardRepairService.new(account: account, apply: apply).perform
      # Counts only: no names, phones, IINs or patient codes are printed.
      puts({ 'account_id' => account.id }.merge(report).to_json)
    end
  end
end
