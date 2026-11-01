require 'rails_helper'
require 'rake'
require 'sidekiq/cron/job'

RSpec.describe 'accounts:ai_usage release tasks' do # rubocop:disable RSpec/DescribeClass
  let(:rollout) { Accounts::AiUsageRollout.current }
  let(:job) { instance_double(Sidekiq::Cron::Job, enabled?: true, klass: 'Accounts::DrainAiUsageJob', cron: '17 * * * * *') }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('accounts:ai_usage:preflight')
    rollout.update!(cutoff_message_id: 0, cursor: 0, prepared_at: Time.current)
    allow(Sidekiq::Cron::Job).to receive(:find).with('drain_ai_usage_job').and_return(job)
    reenable
  end

  def reenable
    %w[prepare preflight activate pause].each { |name| Rake::Task["accounts:ai_usage:#{name}"].reenable }
  end

  it 'refuses activation when the durable pending queue has no registered recovery worker' do
    allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
    expect do
      expect { Rake::Task['accounts:ai_usage:activate'].invoke }.to raise_error(SystemExit)
    end.to output(/NO-GO: scheduled AI usage recovery worker/).to_stderr
    expect(rollout.reload.activated_at).to be_nil
  end

  it 'refuses activation without explicit drain of the old billing writers' do
    with_modified_env('AI_USAGE_LEGACY_WRITERS_DRAINED' => '0') do
      expect { Rake::Task['accounts:ai_usage:activate'].invoke }.to raise_error(RuntimeError, /writers must be drained/)
    end
    expect(rollout.reload.activated_at).to be_nil
  end

  it 'activates idempotently and pauses without dropping queued acknowledgements or reseeding history' do
    message = create(:message, message_type: :outgoing, source_id: 'pending-ack', additional_attributes: { 'captain_ai_reply' => {} })
    with_modified_env('AI_USAGE_LEGACY_WRITERS_DRAINED' => '1') do
      Rake::Task['accounts:ai_usage:activate'].invoke
      first_activation = rollout.reload.activated_at
      reenable
      Rake::Task['accounts:ai_usage:activate'].invoke
      expect(rollout.reload.activated_at).to eq(first_activation)
      Rake::Task['accounts:ai_usage:pause'].invoke
    end
    expect(message.reload).to have_attributes(source_id: 'pending-ack', ai_usage_pending: true)
    expect(rollout.reload).to have_attributes(activated_at: nil, cutoff_message_id: 0, cursor: 0)
  end
end
