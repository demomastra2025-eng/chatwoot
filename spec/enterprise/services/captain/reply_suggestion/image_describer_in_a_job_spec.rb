require 'rails_helper'

# The run of a reply suggestion is a job (GenerateJob): the executor switches the query cache on for the calling thread, and the images
# are described on worker threads. The description that the job of the arrival is making is written through ANOTHER connection (another
# process), and the run must take it instead of paying for a second call. The specs of image_describer_spec.rb share one connection
# and cannot show it. See also ../image_recognition_service_in_a_job_spec.rb.
RSpec.describe Captain::ReplySuggestion::ImageDescriber do
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
  let(:lock_key) { "#{Captain::ImageRecognitionService::LOCK_PREFIX}:#{attachment.id}" }
  let(:own_reading) do
    Captain::ImageReading::Reader::Reading.new(description: 'Own description of the run', reader: :ordinary, model: 'gpt-5.4-mini')
  end
  let(:reader) { instance_double(Captain::ImageReading::Reader, read: own_reading) }
  # Set when a worker has looked at the cache and at the lock once: from then on the job of the arrival may finish.
  let(:worker_looked) { Queue.new }

  before do
    stub_const('Captain::ImageRecognitionService::POLL_SECONDS', 0.02)
    allow(Llm::Config).to receive(:provider_for_model).and_return('openai')
    allow(Captain::ImageRecognitionService).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap { |recognition| allow(recognition).to receive(:model).and_return('gpt-5.4-mini') }
    end
    allow(Captain::ImageReading::Reader).to receive(:new).and_return(reader)
    allow(Redis::Alfred).to receive(:exists?).and_wrap_original do |original, *args|
      original.call(*args).tap { worker_looked << true }
    end
  end

  it 'takes the description the job of the arrival is making: one call in total, none of the run' do
    Redis::Alfred.set(lock_key, 'arrival-job', nx: true, ex: 30)
    arrival_job = Thread.new do
      Timeout.timeout(10) { worker_looked.pop }
      ActiveRecord::Base.connection_pool.with_connection do
        Attachment.find(attachment.id).update!(meta: { Captain::ImageRecognitionService::CACHE_KEY => 'Description from the arrival job' })
      end
      Redis::Alfred.delete(lock_key)
    end

    descriptions = Rails.application.executor.wrap do
      target = Attachment.find(attachment.id)
      described_class.new(account: account, targets: [[target, target.external_url]]).perform
    end
    arrival_job.join

    expect(descriptions).to eq(attachment.id => 'Description from the arrival job')
    expect(reader).not_to have_received(:read)
  end
end
