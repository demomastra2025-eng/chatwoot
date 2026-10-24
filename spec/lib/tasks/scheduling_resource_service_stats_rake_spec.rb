require 'rails_helper'
require 'rake'

RSpec.describe 'onelink:scheduling:resource_service_stats' do # rubocop:disable RSpec/DescribeClass
  let(:task) { Rake::Task['onelink:scheduling:resource_service_stats'] }
  let(:account) { create(:account) }
  let(:doctor) { create(:scheduling_resource, account: account, slot_duration_min: 15) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:scheduling:resource_service_stats')
    task.reenable
    create(:scheduling_service, account: account, custom_attributes: { 'medelement_nomenclature_code' => 'U1' })
    starts_at = 3.days.ago.beginning_of_day + 9.hours
    rows = Array.new(3) do |index|
      { account_id: account.id, resource_id: doctor.id, client_name: 'Patient', status: 'completed', source: 'medelement',
        starts_at: starts_at + (index * 20).minutes, ends_at: starts_at + ((index * 20) + 15).minutes, duration_min: 15,
        custom_attributes: { 'medelement_provider_nomenclature_codes' => ['U1'] } }
    end
    Scheduling::Appointment.insert_all!(rows) # rubocop:disable Rails/SkipsModelValidations
  end

  it 'fills the table of one account and prints counts only' do
    expect { task.invoke(account.id.to_s) }
      .to output(/account #{account.id}: history pairs 1, counting 1, created 1, updated 0, marked stale 0, unchanged 0/).to_stdout

    expect(Scheduling::ResourceServiceStat.where(account_id: account.id).pluck(:receptions_count, :median_duration_min, :status))
      .to eq([[3, 15, 'auto']])
  end

  it 'fills every account with an enabled MedElement integration when no account is given' do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)

    expect { task.invoke }.to output(/1 account\(s\), writing.*account #{account.id}: history pairs 1/m).to_stdout
    expect(Scheduling::ResourceServiceStat.count).to eq(1)
  end

  it 'only prints what it would do on a dry run' do
    expect { task.invoke(account.id.to_s, 'true') }.to output(/DRY RUN.*would create 1/m).to_stdout
    expect(Scheduling::ResourceServiceStat.count).to eq(0)
  end

  it 'refuses an account id and a dry run flag it cannot read' do
    expect { task.invoke('abc') }.to raise_error(ArgumentError, /account_id/)
    task.reenable
    expect { task.invoke(account.id.to_s, 'maybe') }.to raise_error(ArgumentError, /dry_run/)
  end
end
