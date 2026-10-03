# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::StorageThresholdAlertJob, type: :job do
  subject(:job) { described_class.perform_later }

  it 'enqueues on the scheduled_jobs queue' do
    expect { job }.to have_enqueued_job(described_class).on_queue('scheduled_jobs')
  end

  it 'invokes AccountLimits::StorageAlertService.check_all_accounts!' do
    allow(AccountLimits::StorageAlertService).to receive(:check_all_accounts!)
    described_class.new.perform
    expect(AccountLimits::StorageAlertService).to have_received(:check_all_accounts!)
  end
end
