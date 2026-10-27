require 'rails_helper'

RSpec.describe Captain::ImageRecognitionService do
  let(:account) { create(:account) }
  let(:message) { create(:message, account: account) }
  let(:attachment) do
    message.attachments.create!(
      account_id: account.id,
      file_type: :image,
      external_url: 'https://example.com/image.jpg'
    )
  end
  let(:reading) do
    Captain::ImageReading::Reader::Reading.new(description: 'Screenshot with an order error', reader: :ordinary, model: 'gpt-5.4-mini')
  end
  let(:reader) { instance_double(Captain::ImageReading::Reader, read: reading) }
  let(:service) { described_class.new(account: account, attachment: attachment, image_url: attachment.external_url) }

  before do
    allow(service).to receive_messages(model: 'gpt-5.4-mini', handwriting_model: 'openai/gpt-6.1-terra')
    allow(Captain::ImageReading::Reader).to receive(:new).and_return(reader)
  end

  it 'reads the image through the image reader with the two platform models and caches the text with the reader that made it' do
    expect(service.perform).to eq('Screenshot with an order error')

    expect(Captain::ImageReading::Reader).to have_received(:new).with(
      account: account, attachment: attachment, image_url: 'https://example.com/image.jpg',
      models: { ordinary: 'gpt-5.4-mini', handwriting: 'openai/gpt-6.1-terra' }
    )
    expect(attachment.reload.meta).to include(
      'image_recognition_description' => 'Screenshot with an order error',
      'image_recognition_reader' => 'ordinary',
      'image_recognition_model' => 'gpt-5.4-mini'
    )
  end

  it 'caches which reader read an image with handwriting' do
    handwriting = Captain::ImageReading::Reader::Reading.new(description: 'Рецепт', reader: :handwriting, model: 'openai/gpt-6.1-terra')
    allow(reader).to receive(:read).and_return(handwriting)

    service.perform

    expect(attachment.reload.meta).to include('image_recognition_reader' => 'handwriting', 'image_recognition_model' => 'openai/gpt-6.1-terra')
  end

  it 'uses cached image recognition without reading the image again' do
    attachment.update!(meta: { 'image_recognition_description' => 'Cached image description' })

    expect(Captain::ImageReading::Reader).not_to receive(:new)

    expect(service.perform).to eq('Cached image description')
  end

  it 'returns a safe fallback when no image recognition model is available' do
    allow(service).to receive(:model).and_return(nil)

    expect(Captain::ImageReading::Reader).not_to receive(:new)

    expect(service.perform).to eq('User shared an image, but image recognition is temporarily unavailable.')
  end

  it 'returns the fallback, and caches nothing, when the image cannot be read' do
    allow(reader).to receive(:read).and_raise(Captain::ImageReading::Picture::Unreadable, 'the file is not an image')

    expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
    expect(attachment.reload.meta).not_to have_key('image_recognition_description')
  end

  it 'returns the fallback when the reader gave no text' do
    allow(reader).to receive(:read).and_return(Captain::ImageReading::Reader::Reading.new(description: nil, reader: :ordinary, model: 'm'))

    expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
    expect(attachment.reload.meta).not_to have_key('image_recognition_description')
  end

  it 'returns the fallback when the provider rejects the key' do
    allow(reader).to receive(:read).and_raise(RubyLLM::UnauthorizedError.new(nil, 'bad key'))

    expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
  end

  # A reading that fails costs up to 90 s; it must not be paid again by every suggestion and every run of the conversation.
  describe 'a reading that fails' do
    let(:failures_key) { described_class::FAILURE_KEY }

    before { allow(reader).to receive(:read).and_raise(Captain::ImageReading::Picture::Unreadable, 'the image cannot be decoded') }

    it 'is written down on the attachment: the number of attempts, the time and the class of the error, nothing of the image' do
      service.perform

      expect(attachment.reload.meta[failures_key]).to include(
        'count' => 1, 'error' => 'Captain::ImageReading::Picture::Unreadable', 'at' => be_a(String)
      )
      expect(attachment.meta.to_json).not_to match(/example\.com|cannot be decoded/)
    end

    it 'is tried once more, and then no more: the third call gets the fallback at once, without any reading' do
      3.times { expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION) }

      expect(reader).to have_received(:read).twice
      expect(attachment.reload.meta[failures_key]['count']).to eq(2)
    end

    it 'stops the calls of a service made later too, because the memory is on the attachment' do
      2.times { service.perform }
      later = described_class.new(account: account, attachment: Attachment.find(attachment.id), image_url: attachment.external_url)
      allow(later).to receive_messages(model: 'gpt-5.4-mini', handwriting_model: 'openai/gpt-6.1-terra')

      expect(later.perform).to eq(described_class::FALLBACK_DESCRIPTION)
      expect(reader).to have_received(:read).twice
    end

    it 'is read again once the waiting time has passed, and a good reading wipes the memory' do
      2.times { service.perform }

      travel_to((described_class::RETRY_AFTER + 1.minute).from_now) do
        allow(reader).to receive(:read).and_return(reading)

        expect(service.perform).to eq('Screenshot with an order error')
      end
      expect(attachment.reload.meta).not_to have_key(failures_key)
      expect(attachment.meta).to include('image_recognition_description' => 'Screenshot with an order error')
    end

    it 'waits again after a failed attempt that follows the waiting time' do
      2.times { service.perform }

      travel_to((described_class::RETRY_AFTER + 1.minute).from_now) do
        service.perform
        service.perform
      end
      expect(reader).to have_received(:read).exactly(3).times
      expect(attachment.reload.meta[failures_key]['count']).to eq(3)
    end

    it 'counts a reading that gave no text as a failure' do
      allow(reader).to receive(:read).and_return(Captain::ImageReading::Reader::Reading.new(description: nil, reader: :ordinary, model: 'm'))

      service.perform

      expect(attachment.reload.meta[failures_key]).to include('count' => 1, 'error' => 'EmptyReading')
    end

    it 'does not write the key or the models of the platform down against the image' do
      allow(reader).to receive(:read).and_raise(RubyLLM::UnauthorizedError.new(nil, 'bad key'))
      3.times { service.perform }
      allow(reader).to receive(:read).and_raise(Captain::ImageReading::Reader::NoReaderModel, 'no model for the handwriting reader')
      3.times { service.perform }

      expect(attachment.reload.meta).not_to have_key(failures_key)
      expect(reader).to have_received(:read).exactly(6).times
    end

    it 'never raises when the memory cannot be written: the caller gets the fallback' do
      allow(attachment).to receive(:update!).and_raise(ActiveRecord::StatementInvalid)

      expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
    end

    it 'does not make a waiter try for the third time when the holder failed for the second' do
      lock_key = "#{described_class::LOCK_PREFIX}:#{attachment.id}"
      stub_const("#{described_class}::POLL_SECONDS", 0.01)
      Redis::Alfred.set(lock_key, 'other-process', nx: true, ex: 30)
      worker = Thread.new do
        sleep 0.1
        Attachment.find(attachment.id).update!(meta: { failures_key => { 'count' => 2, 'at' => Time.current.iso8601, 'error' => 'X' } })
        Redis::Alfred.delete(lock_key)
      end

      expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
      worker.join

      expect(reader).not_to have_received(:read)
    ensure
      Redis::Alfred.delete(lock_key)
    end
  end

  describe 'the models' do
    let(:plain) { described_class.new(account: account, attachment: attachment, image_url: attachment.external_url) }

    it 'resolves the ordinary model and the handwriting model from the two platform settings, not from the default model' do
      allow(Llm::Config).to receive(:model_for).and_call_original

      plain.model
      plain.handwriting_model

      expect(Llm::Config).to have_received(:model_for).with(feature: 'image_recognition', account: account, fallback: Llm::Config::DEFAULT_MODEL)
      expect(Llm::Config).to have_received(:model_for).with(feature: 'image_handwriting', account: account, fallback: nil)
    end
  end

  # The description made when the image arrived and the one a reply suggestion asks for must not be two paid calls.
  describe 'one call at a time per image' do
    let(:lock_key) { "#{described_class::LOCK_PREFIX}:#{attachment.id}" }
    let(:cache_key) { described_class::CACHE_KEY }

    before do
      stub_const("#{described_class}::POLL_SECONDS", 0.01)
    end

    after { Redis::Alfred.delete(lock_key) }

    # The call another process is making: it holds the lock, and ends by writing the description (or not) and freeing the lock.
    def other_call_ends_after(seconds, description: 'Описание из фонового задания')
      Redis::Alfred.set(lock_key, 'other-process', nx: true, ex: 30)
      Thread.new do
        sleep seconds
        Attachment.find(attachment.id).update!(meta: { cache_key => description }) if description
        Redis::Alfred.delete(lock_key)
      end
    end

    it 'describes the image itself when nobody else does, and frees the lock afterwards' do
      expect(service.perform).to eq('Screenshot with an order error')

      expect(reader).to have_received(:read).once
      expect(Redis::Alfred.exists?(lock_key)).to be(false)
    end

    it 'holds the lock while it describes the image' do
      held = nil
      allow(reader).to receive(:read) do
        held = Redis::Alfred.exists?(lock_key)
        reading
      end

      service.perform

      expect(held).to be(true)
    end

    it 'holds the lock long enough for a slow reading and waits for one as long' do
      # the router (up to 8 s) and a reader that times out (45 s) and is tried once more: 98 s, and the lock must outlive them
      expect(described_class::LOCK_TTL_SECONDS).to be >= 150
      expect(described_class::WAIT_SECONDS).to be >= 20
    end

    it 'waits for the description another call is making instead of making a second one' do
      worker = other_call_ends_after(0.2)

      expect(service.perform).to eq('Описание из фонового задания')
      worker.join

      expect(reader).not_to have_received(:read)
    end

    it 'describes the image itself when the other call ends without a description' do
      worker = other_call_ends_after(0.1, description: nil)

      expect(service.perform).to eq('Screenshot with an order error')
      worker.join

      expect(reader).to have_received(:read).once
      expect(attachment.reload.meta).to include(cache_key => 'Screenshot with an order error')
    end

    it 'describes the image itself when the other call is not done in time' do
      stub_const("#{described_class}::WAIT_SECONDS", 0.2)
      Redis::Alfred.set(lock_key, 'stuck-process', nx: true, ex: 30)

      expect(service.perform).to eq('Screenshot with an order error')

      expect(reader).to have_received(:read).once
      # The stuck holder keeps its lock; this call never took it.
      expect(Redis::Alfred.get(lock_key)).to eq('stuck-process')
    end

    it 'uses the description a holder left between the cache check and the lock' do
      allow(service).to receive(:lock_taken?).and_wrap_original do |original, lock|
        attachment.class.find(attachment.id).update!(meta: { cache_key => 'Описание, которое только что сохранили' })
        original.call(lock)
      end

      expect(service.perform).to eq('Описание, которое только что сохранили')
      expect(reader).not_to have_received(:read)
    end

    it 'describes the image without a lock when Redis fails: the lock only saves a call' do
      lock_manager = instance_double(Redis::LockManager, unlock: false)
      allow(lock_manager).to receive(:lock).and_raise(Redis::BaseConnectionError)
      allow(Redis::LockManager).to receive(:new).and_return(lock_manager)

      expect(service.perform).to eq('Screenshot with an order error')
      expect(reader).to have_received(:read).once
    end

    it 'makes one call when the job of the arrival and a reply suggestion ask for the same image together' do
      calls = Concurrent::AtomicFixnum.new(0)
      allow(reader).to receive(:read) do
        calls.increment
        sleep 0.3
        reading
      end
      other = described_class.new(account: account, attachment: Attachment.find(attachment.id), image_url: attachment.external_url)
      allow(other).to receive_messages(model: 'gpt-5.4-mini', handwriting_model: 'openai/gpt-6.1-terra')

      results = [service, other].map { |recognition| Thread.new { recognition.perform } }.map(&:value)

      expect(results).to eq(['Screenshot with an order error'] * 2)
      expect(calls.value).to eq(1)
    end

    it 'does not share a lock between two images' do
      other = message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/other.jpg')
      Redis::Alfred.set("#{described_class::LOCK_PREFIX}:#{other.id}", 'other-process', nx: true, ex: 30)

      expect(service.perform).to eq('Screenshot with an order error')
      Redis::Alfred.delete("#{described_class::LOCK_PREFIX}:#{other.id}")
    end

    it 'frees the lock when the call fails' do
      allow(reader).to receive(:read).and_raise(Faraday::TimeoutError)

      expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
      expect(Redis::Alfred.exists?(lock_key)).to be(false)
    end
  end
end
