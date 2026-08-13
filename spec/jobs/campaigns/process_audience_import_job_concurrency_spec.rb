require 'rails_helper'
require 'timeout'

RSpec.describe Campaigns::ProcessAudienceImportJob do
  self.use_transactional_tests = false

  it 'does not overwrite a concurrent completion when retries are exhausted' do
    records = create_race_records
    entered = Queue.new
    release = Queue.new
    errors = Concurrent::Array.new
    service = instance_double(Campaigns::AudienceImportService)
    allow(Campaigns::AudienceImportService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(IOError, 'final attempt failed')
    allow(Rails.logger).to receive(:error).and_wrap_original do |original, message|
      if message.include?('exhausted retries')
        entered << true
        release.pop
      end
      original.call(message)
    end
    job = described_class.new(records.fetch(:audience_import))
    job.executions = 2
    job.exception_executions = { [StandardError].to_s => 2 }

    worker = perform_in_thread(job, errors)
    Timeout.timeout(5) { entered.pop }
    complete_import(records.fetch(:audience_import))
    release << true
    worker.join

    expect(errors).to be_empty
    expect(records.fetch(:audience_import).reload).to be_completed
    expect(records.fetch(:audience_import).processing_error).to be_nil
  ensure
    release << true if defined?(release) && release.empty?
    cleanup_race_records(records) if defined?(records)
  end

  it 'does not overwrite a concurrent completion after a domain error' do
    records = create_race_records
    entered = Queue.new
    release = Queue.new
    errors = Concurrent::Array.new
    service = instance_double(Campaigns::AudienceImportService)
    allow(Campaigns::AudienceImportService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(Campaigns::AudienceImportService::Error, 'phone_column_required')
    allow(described_class).to receive(:transition_to_failed).and_wrap_original do |original, audience_import, error_code:|
      entered << true
      release.pop
      original.call(audience_import, error_code: error_code)
    end

    worker = perform_in_thread(described_class.new(records.fetch(:audience_import)), errors)
    Timeout.timeout(5) { entered.pop }
    complete_import(records.fetch(:audience_import))
    release << true
    worker.join

    expect(errors).to be_empty
    expect(records.fetch(:audience_import).reload).to be_completed
    expect(records.fetch(:audience_import).processing_error).to be_nil
  ensure
    release << true if defined?(release) && release.empty?
    cleanup_race_records(records) if defined?(records)
  end

  def create_race_records
    account = create(:account)
    channel = create(
      :channel_sms,
      account: account,
      phone_number: "+1555#{SecureRandom.random_number(10**10).to_s.rjust(10, '0')}"
    )
    creator = create(:user, account: account, role: :administrator)
    audience_import = create(
      :campaign_audience_import,
      account: account,
      inbox: channel.inbox,
      created_by: creator,
      status: :pending
    )
    { account: account, channel: channel, creator: creator, audience_import: audience_import }
  end

  def perform_in_thread(job, errors)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { job.perform_now }
    rescue StandardError => e
      errors << e
    end
  end

  def complete_import(audience_import)
    ActiveRecord::Base.connection_pool.with_connection do
      CampaignAudienceImport.find(audience_import.id).update!(status: :completed)
    end
  end

  def cleanup_race_records(records)
    cleanup_import(records.fetch(:audience_import))
    cleanup_channel(records.fetch(:channel))
    cleanup_account(records.fetch(:account))
    cleanup_creator(records.fetch(:creator))
  end

  def cleanup_import(audience_import)
    if audience_import.persisted? && audience_import.import_file.attached?
      Campaigns::AudienceImportSourcePurgeService.new(audience_import: audience_import).perform
    end
    audience_import.destroy! if audience_import.persisted?
  end

  def cleanup_channel(channel)
    channel.inbox.destroy! if channel.inbox&.persisted?
    channel.destroy! if channel.persisted?
  end

  def cleanup_account(account)
    account.destroy! if account.persisted?
  end

  def cleanup_creator(creator)
    creator.destroy! if creator.persisted?
  end
end
