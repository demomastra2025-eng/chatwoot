require 'rails_helper'

# A job (Sidekiq, ActiveJob) runs inside the Rails executor, which switches the ActiveRecord query cache on. The call that holds the
# lock of an image writes its description through ANOTHER connection (another process), so a waiter that read the cache of the
# attachment through the query cache would keep seeing the blank it read first, and would describe the image a second time (a second
# paid call) as soon as the holder frees the lock. The specs of image_recognition_service_spec.rb share one connection and cannot show it.
RSpec.describe Captain::ImageRecognitionService do
  self.use_transactional_tests = false

  # Rows committed here are not rolled back, and Account#destroy! leaves most of them to destroy_async jobs that never run in specs.
  # Clear them so later specs start clean.
  after do
    Redis::Alfred.delete(lock_key)
    CommittedRowsCleanup.truncate!
  end

  let!(:account) { create(:account) }
  let!(:message) { create(:message, account: account) }
  let!(:attachment) do
    message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/image.jpg')
  end
  let(:lock_key) { "#{described_class::LOCK_PREFIX}:#{attachment.id}" }
  let(:cache_key) { described_class::CACHE_KEY }
  let(:own_reading) do
    Captain::ImageReading::Reader::Reading.new(description: 'Own description of the waiter', reader: :ordinary, model: 'gpt-5.4-mini')
  end
  let(:reader) { instance_double(Captain::ImageReading::Reader, read: own_reading) }
  # Set when the waiter has looked at the cache and at the lock once: from then on the holder may finish.
  let(:waiter_looked) { Queue.new }

  before do
    stub_const("#{described_class}::POLL_SECONDS", 0.02)
    allow(Llm::Config).to receive(:provider_for_model).and_return('openai')
    allow(Captain::ImageReading::Reader).to receive(:new).and_return(reader)
    allow(Redis::Alfred).to receive(:exists?).and_wrap_original do |original, *args|
      original.call(*args).tap { waiter_looked << true }
    end
  end

  def waiter
    described_class.new(account: account, attachment: Attachment.find(attachment.id), image_url: attachment.external_url).tap do |service|
      allow(service).to receive(:model).and_return('gpt-5.4-mini')
    end
  end

  # The other process: it holds the lock, and when the waiter has looked it writes the description (if it made one) on a connection of
  # its own and frees the lock.
  def holder_ends_after_the_first_look(description)
    Redis::Alfred.set(lock_key, 'other-process', nx: true, ex: 30)
    Thread.new do
      Timeout.timeout(10) { waiter_looked.pop }
      if description
        ActiveRecord::Base.connection_pool.with_connection do
          Attachment.find(attachment.id).update!(meta: { cache_key => description })
        end
      end
      Redis::Alfred.delete(lock_key)
    end
  end

  it 'takes the description of the holder instead of describing the image again' do
    holder = holder_ends_after_the_first_look('Description from the holder')

    expect(waiter.perform).to eq('Description from the holder')
    holder.join

    expect(reader).not_to have_received(:read)
  end

  it 'takes the description of the holder inside the executor of a job, where the query cache is on' do
    holder = holder_ends_after_the_first_look('Description from the holder')

    result = Rails.application.executor.wrap do
      expect(ActiveRecord::Base.connection_pool.query_cache_enabled).to be(true)
      waiter.perform
    end
    holder.join

    expect(result).to eq('Description from the holder')
    expect(reader).not_to have_received(:read)
  end

  it 'describes the image once inside the executor of a job when the holder ends without a description' do
    holder = holder_ends_after_the_first_look(nil)

    result = Rails.application.executor.wrap { waiter.perform }
    holder.join

    expect(result).to eq('Own description of the waiter')
    expect(reader).to have_received(:read).once
  end
end
