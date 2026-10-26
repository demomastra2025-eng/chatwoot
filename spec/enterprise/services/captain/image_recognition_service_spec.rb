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
  let(:response) { instance_double(RubyLLM::Message, content: 'Screenshot with an order error') }
  let(:service) { described_class.new(account: account, attachment: attachment, image_url: attachment.external_url) }

  before do
    allow(service).to receive(:model).and_return('gpt-5.4-mini')
    allow(Llm::Config).to receive(:provider_for_model).with('gpt-5.4-mini', account: account).and_return('openai')
  end

  it 'recognizes an image through the configured image recognition model and caches the result' do
    expect(Llm::Runtime).to receive(:chat) do |feature:, account:, model:, messages:, observability:, options:|
      content = messages.first[:content]
      expect(feature).to eq(:image_recognition)
      expect(account).to eq(service.account)
      expect(model).to eq('gpt-5.4-mini')
      expect(content).to be_a(RubyLLM::Content)
      expect(content.text).to include('Describe the attached customer-shared image')
      expect(content.attachments.first.source.to_s).to eq('https://example.com/image.jpg')
      expect(observability).to include(runtime_mode: 'image_recognition', feature_name: 'image_recognition')
      expect(options).to include(temperature: 0)
      response
    end

    expect(service.perform).to eq('Screenshot with an order error')
    expect(attachment.reload.meta).to include('image_recognition_description' => 'Screenshot with an order error')
  end

  it 'uses cached image recognition without calling the model' do
    attachment.update!(meta: { 'image_recognition_description' => 'Cached image description' })

    expect(Llm::Runtime).not_to receive(:chat)

    expect(service.perform).to eq('Cached image description')
  end

  it 'returns a safe fallback when no image recognition model is available' do
    allow(service).to receive(:model).and_return(nil)

    expect(Llm::Runtime).not_to receive(:chat)

    expect(service.perform).to eq('User shared an image, but image recognition is temporarily unavailable.')
  end

  # The description made when the image arrived and the one a reply suggestion asks for must not be two paid calls.
  describe 'one call at a time per image' do
    let(:lock_key) { "#{described_class::LOCK_PREFIX}:#{attachment.id}" }
    let(:cache_key) { described_class::CACHE_KEY }

    before do
      stub_const("#{described_class}::POLL_SECONDS", 0.01)
      allow(Llm::Runtime).to receive(:chat).and_return(response)
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

      expect(Llm::Runtime).to have_received(:chat).once
      expect(Redis::Alfred.exists?(lock_key)).to be(false)
    end

    it 'holds the lock while it describes the image' do
      held = nil
      allow(Llm::Runtime).to receive(:chat) do
        held = Redis::Alfred.exists?(lock_key)
        response
      end

      service.perform

      expect(held).to be(true)
    end

    it 'waits for the description another call is making instead of making a second one' do
      worker = other_call_ends_after(0.2)

      expect(service.perform).to eq('Описание из фонового задания')
      worker.join

      expect(Llm::Runtime).not_to have_received(:chat)
    end

    it 'describes the image itself when the other call ends without a description' do
      worker = other_call_ends_after(0.1, description: nil)

      expect(service.perform).to eq('Screenshot with an order error')
      worker.join

      expect(Llm::Runtime).to have_received(:chat).once
      expect(attachment.reload.meta).to include(cache_key => 'Screenshot with an order error')
    end

    it 'describes the image itself when the other call is not done in time' do
      stub_const("#{described_class}::WAIT_SECONDS", 0.2)
      Redis::Alfred.set(lock_key, 'stuck-process', nx: true, ex: 30)

      expect(service.perform).to eq('Screenshot with an order error')

      expect(Llm::Runtime).to have_received(:chat).once
      # The stuck holder keeps its lock; this call never took it.
      expect(Redis::Alfred.get(lock_key)).to eq('stuck-process')
    end

    it 'uses the description a holder left between the cache check and the lock' do
      allow(service).to receive(:lock_taken?).and_wrap_original do |original, lock|
        attachment.class.find(attachment.id).update!(meta: { cache_key => 'Описание, которое только что сохранили' })
        original.call(lock)
      end

      expect(service.perform).to eq('Описание, которое только что сохранили')
      expect(Llm::Runtime).not_to have_received(:chat)
    end

    it 'describes the image without a lock when Redis fails: the lock only saves a call' do
      lock_manager = instance_double(Redis::LockManager, unlock: false)
      allow(lock_manager).to receive(:lock).and_raise(Redis::BaseConnectionError)
      allow(Redis::LockManager).to receive(:new).and_return(lock_manager)

      expect(service.perform).to eq('Screenshot with an order error')
      expect(Llm::Runtime).to have_received(:chat).once
    end

    it 'makes one call when the job of the arrival and a reply suggestion ask for the same image together' do
      calls = Concurrent::AtomicFixnum.new(0)
      allow(Llm::Runtime).to receive(:chat) do
        calls.increment
        sleep 0.3
        response
      end
      other = described_class.new(account: account, attachment: Attachment.find(attachment.id), image_url: attachment.external_url)
      allow(other).to receive(:model).and_return('gpt-5.4-mini')

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
      allow(Llm::Runtime).to receive(:chat).and_raise(Faraday::TimeoutError)

      expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
      expect(Redis::Alfred.exists?(lock_key)).to be(false)
    end
  end
end
