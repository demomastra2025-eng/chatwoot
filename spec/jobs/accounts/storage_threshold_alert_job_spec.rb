# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::StorageThresholdAlertJob, type: :job do
  subject(:job) { described_class.perform_later }

  it 'enqueues on the housekeeping queue, which the main Sidekiq worker consumes' do
    expect { job }.to have_enqueued_job(described_class).on_queue('housekeeping')
  end

  it 'invokes AccountLimits::StorageAlertService.check_all_accounts!' do
    allow(AccountLimits::StorageAlertService).to receive(:check_all_accounts!)
    described_class.new.perform
    expect(AccountLimits::StorageAlertService).to have_received(:check_all_accounts!)
  end

  it 'checks just one account when an id is given' do
    account = create(:account)
    service = instance_double(AccountLimits::StorageAlertService, perform: { status: :normal })
    allow(AccountLimits::StorageAlertService).to receive(:new).with(account: account).and_return(service)
    allow(AccountLimits::StorageAlertService).to receive(:check_all_accounts!)

    described_class.new.perform(account.id)

    expect(service).to have_received(:perform)
    expect(AccountLimits::StorageAlertService).not_to have_received(:check_all_accounts!)
  end

  it 'ignores an account that no longer exists' do
    expect { described_class.new.perform(0) }.not_to raise_error
  end
end
