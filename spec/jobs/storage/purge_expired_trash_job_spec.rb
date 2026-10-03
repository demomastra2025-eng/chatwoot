# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Storage::PurgeExpiredTrashJob, type: :job do
  subject(:job) { described_class.perform_later }

  it 'enqueues on the scheduled_jobs queue' do
    expect { job }.to have_enqueued_job(described_class).on_queue('scheduled_jobs')
  end

  it 'invokes Storage::TrashService.purge_expired_all!' do
    allow(Storage::TrashService).to receive(:purge_expired_all!)
    described_class.new.perform
    expect(Storage::TrashService).to have_received(:purge_expired_all!)
  end
end
