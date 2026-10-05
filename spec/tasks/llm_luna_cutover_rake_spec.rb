# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'llm:luna_cutover rake tasks' do # rubocop:disable RSpec/DescribeClass
  let(:snapshot_path) { Rails.root.join("tmp/luna_cutover_rake_spec_#{SecureRandom.hex(4)}.json") }
  let!(:account) { create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna', 'copilot' => 'gpt-5.4' }) }

  def run_task(name, **env)
    task = Rake::Task["llm:luna_cutover:#{name}"]
    task.reenable
    output = StringIO.new
    $stdout = output
    with_modified_env(env.transform_values(&:to_s)) { task.invoke }
    output.string
  ensure
    $stdout = STDOUT
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('llm:luna_cutover:preview')
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_DEFAULT_MODEL').update!(value: 'openai/gpt-5.6-luna')
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPENROUTER_API_KEY').update!(value: 'test-key')
    InstallationConfig.where(name: %w[CAPTAIN_AI_AGENT_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST]).destroy_all
  end

  after { FileUtils.rm_f(snapshot_path) }

  it 'previews without changing data and without a snapshot unless one is asked for' do
    output = run_task('preview')

    expect(output).to include('CAPTAIN_DEFAULT_MODEL: openai/gpt-5.6-luna -> openai/gpt-6-luna', "accounts #{account.id}")
    expect(output).to include('No snapshot written')
    expect(account.reload.captain_models).to eq('assistant' => 'openai/gpt-5.6-luna', 'copilot' => 'gpt-5.4')
    expect(InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').value).to eq('openai/gpt-5.6-luna')
  end

  it 'writes the verified private snapshot from the preview' do
    output = run_task('preview', SNAPSHOT: snapshot_path)

    expect(output).to include('Snapshot written and verified (mode 0600)')
    expect(snapshot_path.stat.mode & 0o777).to eq(0o600)
    expect(account.reload.captain_models).to include('assistant' => 'openai/gpt-5.6-luna')
  end

  it 'applies only with CONFIRM=yes and rolls back to exactly the old values', :aggregate_failures do
    run_task('preview', SNAPSHOT: snapshot_path)

    expect(run_task('apply', SNAPSHOT: snapshot_path)).to include('Dry run, nothing changed')
    expect(account.reload.captain_models).to include('assistant' => 'openai/gpt-5.6-luna')
    expect(run_task('apply', SNAPSHOT: snapshot_path, CONFIRM: 'no')).to include('Dry run, nothing changed')

    expect(run_task('apply', SNAPSHOT: snapshot_path, CONFIRM: 'yes')).to include('Applied')
    expect(account.reload.captain_models).to eq({})
    expect(InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').value).to eq('openai/gpt-6-luna')

    expect(run_task('rollback', SNAPSHOT: snapshot_path)).to include('Dry run, nothing changed')
    expect(account.reload.captain_models).to eq({})
    expect(run_task('rollback', SNAPSHOT: snapshot_path, CONFIRM: 'yes')).to include('Rolled back', 'as in the snapshot')
    expect(account.reload.captain_models).to eq('assistant' => 'openai/gpt-5.6-luna', 'copilot' => 'gpt-5.4')
    expect(InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').value).to eq('openai/gpt-5.6-luna')
  end

  it 'needs the snapshot and refuses a stale one even with CONFIRM=yes' do
    expect { run_task('apply', CONFIRM: 'yes') }.to raise_error(SystemExit)

    run_task('preview', SNAPSHOT: snapshot_path)
    account.update!(captain_models: { 'assistant' => 'openai/gpt-6-luna' })

    expect { run_task('apply', SNAPSHOT: snapshot_path, CONFIRM: 'yes') }.to raise_error(Llm::CaptainLunaRollout::StalePlan)
    expect(InstallationConfig.find_by!(name: 'CAPTAIN_DEFAULT_MODEL').value).to eq('openai/gpt-5.6-luna')
  end
end
