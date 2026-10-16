# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'accounts:plan_report rake task' do # rubocop:disable RSpec/DescribeClass
  def run_task(**env)
    task = Rake::Task['accounts:plan_report']
    task.reenable
    output = StringIO.new
    $stdout = output
    with_modified_env(env.transform_values(&:to_s)) { task.invoke }
    output.string
  ensure
    $stdout = STDOUT
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('accounts:plan_report')
  end

  let!(:using_broadcasts) do
    create(:account, name: 'Using broadcasts').tap do |record|
      record.disable_features!(*Featurable::FEATURE_NAMES)
      record.enable_features!('campaigns', 'captain_scheduling_grounding_guard')
    end
  end
  let!(:already_on_plan) do
    create(:account, name: 'Already on the plan').tap do |record|
      record.disable_features!(*Featurable::FEATURE_NAMES)
      Accounts::ApplyPlan.new(account: record, modules: %w[quality]).call
    end
  end

  it 'prints per account what base plus the modules it already uses would change' do
    output = run_task(ACCOUNT_ID: '')

    expect(output).to include('Plan report (read-only')
    expect(output).to include("##{using_broadcasts.id} Using broadcasts | modules used: broadcasts")
    expect(output).to match(/disable \(1\): captain_scheduling_grounding_guard/)
    expect(output).to match(/enable\s+\(\d+\):.*\bcrm\b/)
    expect(output).to include('limit conversations: nil -> 100000')
    expect(output).to include("##{already_on_plan.id} Already on the plan | modules used: quality")
    expect(output).to include('    no change')
  end

  it 'writes nothing: no flag, no limit, no attribute, no audit row' do
    stored = Account.order(:id).map(&:attributes)

    expect { run_task(ACCOUNT_ID: '') }.not_to change(Audited::Audit, :count)

    expect(Account.order(:id).map(&:attributes)).to eq(stored)
  end

  it 'can be narrowed to one account' do
    output = run_task(ACCOUNT_ID: using_broadcasts.id)

    expect(output).to include('Using broadcasts')
    expect(output).not_to include('Already on the plan')
    expect(output).to include('Accounts: 1')
  end

  it 'counts a module as used when any of its flags is on' do
    expect(Accounts::PlanReport.used_modules(using_broadcasts)).to eq(%w[broadcasts])
    expect(Accounts::PlanReport.used_modules(already_on_plan)).to eq(%w[quality])
  end
end
