# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Storage::PurgeExpiredTrashJob, type: :job do
  subject(:job) { described_class.perform_later }

  it 'enqueues on the housekeeping queue, which the main Sidekiq worker consumes' do
    expect { job }.to have_enqueued_job(described_class).on_queue('housekeeping')
  end

  it 'invokes Storage::TrashService.purge_expired_all!' do
    allow(Storage::TrashService).to receive(:purge_expired_all!)
    described_class.new.perform
    expect(Storage::TrashService).to have_received(:purge_expired_all!)
  end
end
