require 'rails_helper'

RSpec.describe Captain::ImageReading::Reader do
  let(:account) { create(:account, custom_attributes: { 'industry' => 'Furniture shop' }) }
  let(:message) { create(:message, account: account) }
  let(:attachment) { message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://cdn.example.com/p.jpg') }
  let(:models) { { ordinary: 'google/gemini-3.1-flash-lite', handwriting: 'openai/gpt-6.1-terra' } }
  let(:picture) do
    bytes = Vips::Image.black(3000, 2000, bands: 3).new_from_image([90, 90, 90]).write_to_buffer('.jpg')
    Captain::ImageReading::Picture.new(bytes: bytes, content_type: 'image/jpeg')
  end
  let(:response) { instance_double(RubyLLM::Message, content: " Приём 12.10 \n", input_tokens: 1200, output_tokens: 300) }
  let(:reader) { described_class.new(account: account, attachment: attachment, image_url: attachment.external_url, models: models) }

  def decision(reader:, probability: 0.1, status: 'ok')
    Captain::ImageReading::Router::Decision.new(
      reader: reader, status: status, choice: 'no_handwriting', probability: probability,
      model: 'perplexity/pplx-decider-v1.2-20261020', latency_ms: 480, cost: 0.00002
    )
  end

  before do
    allow(Llm::Models).to receive(:estimated_text_cost).and_return(BigDecimal('0.00071'))
    allow(Captain::ImageReading::Picture).to receive(:load).and_return(picture)
    allow(Llm::Runtime).to receive(:chat).and_return(response)
    router = instance_double(Captain::ImageReading::Router, decide: decision(reader: :ordinary))
    allow(Captain::ImageReading::Router).to receive(:new).and_return(router)
  end

  def sent_request
    request = nil
    expect(Llm::Runtime).to have_received(:chat) { |**kwargs| request = kwargs }
    request
  end

  describe 'an ordinary image' do
    it 'is read by the ordinary model, the image sent as data inside the request', :aggregate_failures do
      reading = reader.read

      request = sent_request
      expect(reading.description).to eq('Приём 12.10')
      expect(reading.reader).to eq(:ordinary)
      expect(reading.model).to eq('google/gemini-3.1-flash-lite')
      expect(request[:feature]).to eq(:image_recognition)
      expect(request[:model]).to eq('google/gemini-3.1-flash-lite')
      content = request[:messages].first[:content]
      expect(content).to be_a(RubyLLM::Content)
      attached = content.attachments.first
      expect(attached.url?).to be(false)
      expect(attached.for_llm).to start_with('data:image/jpeg;base64,')
    end

    it 'sends the image shrunk to 1536 px, not the original' do
      reader.read

      attached = sent_request[:messages].first[:content].attachments.first
      sent = Vips::Image.new_from_buffer(attached.content, '')
      expect([sent.width, sent.height].max).to eq(1536)
    end

    it 'sends the universal instruction with the industry of the account as the only business context' do
      reader.read

      text = sent_request[:messages].first[:content].text
      expect(text).to start_with('Сфера компании: Furniture shop. Это изображение клиент прислал в чат компании.')
      expect(text).to include('[неразборчиво]')
    end

    it 'leaves the industry line out when the workspace profile has none' do
      account.update!(custom_attributes: {})

      reader.read

      expect(sent_request[:messages].first[:content].text).to eq(Captain::ImageReading::Prompt::READ)
    end

    it 'asks for an answer with room for a reasoning reader' do
      reader.read

      expect(sent_request[:max_tokens]).to eq(4000)
    end

    it 'sends the temperature 0 to a model that takes one' do
      reader.read
      expect(sent_request[:options]).to include(temperature: 0.0)
      expect(sent_request[:options][:params]).not_to have_key(Llm::OpenRouterServerToolsPatch::OMIT_TEMPERATURE_PARAM)
    end

    it 'puts no link and no pixels into what is logged' do
      reader.read

      logged = sent_request[:observability]
      expect(logged).to include(runtime_mode: 'image_recognition', feature_name: 'image_recognition', attachment_id: attachment.id)
      expect(logged.to_s).not_to match(/image_url|base64|example\.com/)
    end
  end

  describe 'a text that the output limit cut off' do
    def answered_with(finish_reason)
      raw = instance_double(Faraday::Response, body: { 'choices' => [{ 'finish_reason' => finish_reason }] })
      instance_double(RubyLLM::Message, content: 'Анализ крови: гемоглобин 134', input_tokens: 1200, output_tokens: 4000, raw: raw)
    end

    it 'says so at its end, so the agent does not take it for the whole text' do
      allow(Llm::Runtime).to receive(:chat).and_return(answered_with('length'))

      reading = reader.read

      expect(reading.description).to eq("Анализ крови: гемоглобин 134\n#{described_class::CUT_MARK}")
      expect(reading.finish_reason).to eq('length')
    end

    it 'leaves a text that ended by itself as it is' do
      allow(Llm::Runtime).to receive(:chat).and_return(answered_with('stop'))

      expect(reader.read.description).to eq('Анализ крови: гемоглобин 134')
    end

    it 'puts the reason the model stopped into the record of the reading' do
      allow(Llm::Runtime).to receive(:chat).and_return(answered_with('length'))
      published = []
      subscriber = ActiveSupport::Notifications.subscribe(described_class::EVENT) { |*, payload| published << payload }

      reader.read

      expect(published.first).to include('finish_reason' => 'length')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'is no fault when the provider says nothing about it' do
      expect(reader.read).to have_attributes(finish_reason: nil, description: 'Приём 12.10')
    end
  end

  describe 'an image that cannot be decoded' do
    let(:picture) { Captain::ImageReading::Picture.new(bytes: "\xFF\xD8\xFF\xE0\x00\x10JFIF damaged".b, content_type: 'image/jpeg') }

    it 'ends the reading as an unreadable image, before the router is asked and without a failed router on the record' do
      published = []
      subscriber = ActiveSupport::Notifications.subscribe(described_class::EVENT) { |*, payload| published << payload }

      expect { reader.read }.to raise_error(Captain::ImageReading::Picture::Unreadable)

      expect(Captain::ImageReading::Router).not_to have_received(:new)
      expect(Llm::Runtime).not_to have_received(:chat)
      expect(published.first).to include('status' => 'error', 'error_class' => 'Captain::ImageReading::Picture::Unreadable')
      expect(published.first).not_to have_key('router_status')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  describe 'an image with handwriting' do
    before do
      router = instance_double(Captain::ImageReading::Router, decide: decision(reader: :handwriting, probability: 0.82))
      allow(Captain::ImageReading::Router).to receive(:new).and_return(router)
    end

    it 'is read by the handwriting model' do
      reading = reader.read

      expect(reading.reader).to eq(:handwriting)
      expect(reading.model).to eq('openai/gpt-6.1-terra')
      expect(sent_request[:model]).to eq('openai/gpt-6.1-terra')
    end

    it 'sends no temperature to Terra, which rejects it' do
      reader.read

      expect(sent_request[:options]).not_to have_key(:temperature)
      expect(sent_request[:options][:params]).to include(Llm::OpenRouterServerToolsPatch::OMIT_TEMPERATURE_PARAM => true)
    end
  end

  describe 'when the router fails' do
    it 'is read by the handwriting model' do
      router = instance_double(Captain::ImageReading::Router, decide: decision(reader: :handwriting, probability: nil, status: 'failed'))
      allow(Captain::ImageReading::Router).to receive(:new).and_return(router)

      expect(reader.read.model).to eq('openai/gpt-6.1-terra')
    end
  end

  describe 'a missing model' do
    it 'raises, with no other model to fall back to' do
      reader = described_class.new(account: account, attachment: attachment, image_url: 'x', models: { ordinary: 'a/b', handwriting: nil })
      router = instance_double(Captain::ImageReading::Router, decide: decision(reader: :handwriting))
      allow(Captain::ImageReading::Router).to receive(:new).and_return(router)

      expect { reader.read }.to raise_error(described_class::NoReaderModel)
      expect(Llm::Runtime).not_to have_received(:chat)
    end
  end

  describe 'the record of the reading (llm_events)' do
    let(:published) { [] }

    around do |example|
      subscriber = ActiveSupport::Notifications.subscribe(described_class::EVENT) do |_name, _start, _finish, _id, payload|
        published << payload
      end
      example.run
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'carries the router decision, its probability, the reader, the latencies and the tokens' do
      router = instance_double(Captain::ImageReading::Router, decide: decision(reader: :handwriting, probability: 0.8231))
      allow(Captain::ImageReading::Router).to receive(:new).and_return(router)

      reader.read

      expect(published.size).to eq(1)
      expect(published.first).to include(
        'feature' => 'image_recognition', 'account_id' => account.id, 'attachment_id' => attachment.id, 'status' => 'success',
        'reader' => 'handwriting', 'model' => 'openai/gpt-6.1-terra', 'router_status' => 'ok',
        'router_model' => 'perplexity/pplx-decider-v1.2-20261020', 'router_choice' => 'no_handwriting', 'router_probability' => 0.8231,
        'router_ms' => 480, 'router_cost' => 0.00002, 'reader_usage' => { 'input_tokens' => 1200, 'output_tokens' => 300 },
        'reader_cost' => 0.00071, 'total_cost' => 0.00073
      )
      expect(published.first['reader_ms']).to be_a(Integer)
    end

    it 'says that the router failed' do
      failed = decision(reader: :handwriting, probability: nil, status: 'failed')
      failed.error_class = 'Timeout::Error'
      failed.model = nil
      allow(Captain::ImageReading::Router).to receive(:new).and_return(instance_double(Captain::ImageReading::Router, decide: failed))

      reader.read

      expect(published.first).to include('router_status' => 'failed', 'router_error_class' => 'Timeout::Error', 'reader' => 'handwriting')
      expect(published.first).not_to have_key('router_probability')
    end

    it 'records a failed reading with its error' do
      allow(Llm::Runtime).to receive(:chat).and_raise(Faraday::TimeoutError)

      expect { reader.read }.to raise_error(Faraday::TimeoutError)

      expect(published.first).to include('status' => 'error', 'error' => true, 'error_class' => 'Faraday::TimeoutError')
      # the decision of the router is on the record although the reader failed after it
      expect(published.first).to include('reader' => 'ordinary', 'router_status' => 'ok', 'router_probability' => 0.1)
    end

    it 'holds neither the image, a link to it nor the text read from it' do
      reader.read

      expect(published.first.to_s).not_to match(/base64|example\.com|Приём/)
    end

    it 'is persisted as an llm_event with the model and the duration, and the dollars only in the payload (no double count)' do
      reader.read
      payload = published.first

      event = Llm::Monitoring::EventRecorder.record_notification(
        event_name: described_class::EVENT, started_at: Time.current - 2, finished_at: Time.current, payload: payload
      )

      expect(event).to be_persisted
      expect(event).to have_attributes(
        event_name: 'captain.image.read', feature: 'image_recognition', model: 'google/gemini-3.1-flash-lite', account_id: account.id,
        prompt_tokens: nil, completion_tokens: nil, estimated_cost: nil
      )
      expect(event.duration_ms).to be_between(1900, 2500)
      expect(event.payload).to include(
        'reader' => 'ordinary', 'router_status' => 'ok', 'router_probability' => 0.1, 'total_cost' => 0.00073,
        'reader_usage' => { 'input_tokens' => 1200, 'output_tokens' => 300 }
      )
    end
  end
end
