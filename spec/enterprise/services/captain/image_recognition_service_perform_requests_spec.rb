require 'rails_helper'

# The requests OpenRouter really receives for a customer's image. Only the outgoing HTTP calls are stubbed: the service, the picture, the
# router, the reader, Llm::Runtime, the routing profile and the HTTP clients run as they do in production, so a model, a provider
# limit, a size or a temperature that is lost on the way fails here (the unit specs stub Llm::Runtime and cannot see that).
RSpec.describe Captain::ImageRecognitionService, '#perform', type: :service do
  let(:api_base) { 'https://openrouter.example/api/v1' }
  let(:decisions_url) { 'https://openrouter.example/api/alpha/decisions' }
  let(:chat_url) { "#{api_base}/chat/completions" }
  let(:account) { create(:account, custom_attributes: { 'industry' => 'Мебельный магазин' }) }
  let(:message) { create(:message, conversation: create(:conversation, account: account), account: account) }
  let(:attachment) { message.attachments.create!(account: account, file_type: :image) }
  let(:service) { described_class.new(account: account, attachment: attachment, image_url: attachment.download_url) }
  let(:image_bytes) { Vips::Image.black(3000, 2000, bands: 3).new_from_image([120, 130, 140]).write_to_buffer('.jpg') }
  let(:decisions_sent) { [] }
  let(:chats_sent) { [] }
  let(:router_probability) { 0.05 }
  let(:router_status) { 200 }
  let(:with_file) { true }

  def router_answer
    {
      id: 'gen-dec-1', model: 'perplexity/pplx-decider-v1.2-20261016', provider: 'Perplexity',
      answers: { reason: { choice: router_probability >= 0.5 ? 'handwriting' : 'no_handwriting', confidence: 0.9,
                           probabilities: { handwriting: router_probability, no_handwriting: 1.0 - router_probability } } },
      usage: { input_tokens: 700, output_tokens: 1, cost: 0.0000044 }
    }
  end

  def chat_answer(model, text)
    {
      id: 'gen-chat-1', model: model, provider: 'Google',
      usage: { prompt_tokens: 1120, completion_tokens: 80, cost: 0.0004 },
      choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: text } }]
    }
  end

  before do
    Llm::EventSubscriber.install!
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'synthetic-openrouter-key')
    upsert_installation_config('CAPTAIN_OPENROUTER_ENDPOINT', api_base)
    %w[CAPTAIN_IMAGE_RECOGNITION_MODEL CAPTAIN_IMAGE_HANDWRITING_MODEL CAPTAIN_IMAGE_ROUTER_MODEL].each do |name|
      upsert_installation_config(name, '')
    end
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})
    attachment.file.attach(io: StringIO.new(image_bytes), filename: 'photo.jpg', content_type: 'image/jpeg') if with_file
    stub_request(:post, decisions_url)
      .with { |http_request| decisions_sent << JSON.parse(http_request.body) }
      .to_return(status: router_status, body: router_answer.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, chat_url)
      .with { |http_request| chats_sent << JSON.parse(http_request.body) }
      .to_return do |http_request|
        answer = chat_answer(JSON.parse(http_request.body)['model'], 'Квитанция 12 000')
        { status: 200, headers: { 'Content-Type' => 'application/json' }, body: answer.to_json }
      end
  end

  after { Llm::EventSubscriber.uninstall! }

  def image_part(body)
    body['messages'].find { |entry| entry['role'] == 'user' }['content'].find { |part| part['type'] == 'image_url' }
  end

  def text_part(body)
    body['messages'].find { |entry| entry['role'] == 'user' }['content'].find { |part| part['type'] == 'text' }['text']
  end

  context 'with an ordinary image' do
    it 'asks the router once with a 1024 px jpeg as data, only of Perplexity, and reads with Gemini only of Google', :aggregate_failures do
      expect(service.perform).to eq('Квитанция 12 000')

      expect(decisions_sent.size).to eq(1)
      router = decisions_sent.first
      expect(router['model']).to eq('perplexity/pplx-decider-v1.2')
      expect(router['provider']).to include('only' => %w[perplexity], 'data_collection' => 'deny')
      text, image = router['state']
      expect(text).to be_a(String)
      expect(image['image_url']['url']).to start_with('data:image/jpeg;base64,')
      sent = Vips::Image.new_from_buffer(Base64.decode64(image['image_url']['url'].split(',', 2).last), '')
      expect([sent.width, sent.height].max).to eq(1024)
      expect(router['questions']['reason']['criteria'].keys).to eq(%w[handwriting no_handwriting])

      expect(chats_sent.size).to eq(1)
      chat = chats_sent.first
      expect(chat['model']).to eq('google/gemini-3.1-flash-lite')
      expect(chat['provider']).to include('only' => %w[google-vertex google-ai-studio], 'data_collection' => 'deny')
      expect(chat['models']).to eq(['google/gemini-3.1-flash-lite']) # the reader only: no fallback model
      expect(chat['max_tokens']).to eq(4000)
      expect(chat['temperature']).to eq(0)
    end

    it 'sends the picture as data, shrunk to 1536 px, with the universal instruction and the industry of the account', :aggregate_failures do
      service.perform

      chat = chats_sent.first
      url = image_part(chat)['image_url']['url']
      expect(url).to start_with('data:image/jpeg;base64,')
      sent = Vips::Image.new_from_buffer(Base64.decode64(url.split(',', 2).last), '')
      expect([sent.width, sent.height]).to eq([1536, 1024])
      expect(text_part(chat)).to start_with('Сфера компании: Мебельный магазин. Это изображение клиент прислал в чат компании.')
      expect(chat.to_json).not_to include('example.com', attachment.download_url.to_s)
    end

    it 'sends a small image as it is' do
      small = Vips::Image.black(800, 600, bands: 3).new_from_image([10, 20, 30]).write_to_buffer('.jpg', strip: true)
      attachment.file.attach(io: StringIO.new(small), filename: 'small.jpg', content_type: 'image/jpeg')

      service.perform

      url = image_part(chats_sent.first)['image_url']['url']
      expect(Base64.decode64(url.split(',', 2).last)).to eq(small.b)
    end

    it 'keeps the description and the reader that made it on the attachment, and asks nobody the second time', :aggregate_failures do
      service.perform

      expect(attachment.reload.meta).to include(
        'image_recognition_description' => 'Квитанция 12 000',
        'image_recognition_reader' => 'ordinary',
        'image_recognition_model' => 'google/gemini-3.1-flash-lite'
      )
      described_class.new(account: account, attachment: attachment.reload, image_url: attachment.download_url).perform
      expect(chats_sent.size).to eq(1)
      expect(decisions_sent.size).to eq(1)
    end

    it 'writes one llm_event of the reading: router decision and probability, reader, latencies, tokens', :aggregate_failures do
      service.perform

      event = LlmEvent.find_by!(account_id: account.id, event_name: 'captain.image.read')
      expect(event).to have_attributes(feature: 'image_recognition', model: 'google/gemini-3.1-flash-lite', status: 'success')
      # the dollars and the tokens of the calls are counted on the rows of the calls, not a second time on this one
      expect(event).to have_attributes(prompt_tokens: nil, completion_tokens: nil, estimated_cost: nil)
      expect(event.duration_ms).to be >= 0
      expect(event.payload).to include(
        'reader' => 'ordinary', 'router_status' => 'ok', 'router_choice' => 'no_handwriting', 'router_probability' => 0.05,
        'router_model' => 'perplexity/pplx-decider-v1.2-20261016', 'router_cost' => 0.0000044, 'attachment_id' => attachment.id,
        'reader_usage' => { 'input_tokens' => 1120, 'output_tokens' => 80 }
      )
      expect(event.payload['router_ms']).to be_a(Integer)
      expect(event.payload['reader_ms']).to be_a(Integer)
      expect(event.payload.to_json).not_to match(/base64|Квитанция|example\.com/)
      expect(LlmEvent.where(account_id: account.id, event_name: 'llm.decision.complete', feature: 'image_routing')).to exist
    end
  end

  context 'with handwriting (P at or above 0.3)' do
    let(:router_probability) { 0.3 }

    it 'reads with Terra only of OpenAI or Azure, without a temperature', :aggregate_failures do
      service.perform

      chat = chats_sent.first
      expect(chat['model']).to eq('openai/gpt-6.1-terra')
      expect(chat['provider']).to include('only' => %w[openai azure], 'data_collection' => 'deny')
      expect(chat).not_to have_key('temperature')
      expect(chat['max_tokens']).to eq(4000)
      expect(chat['models']).to eq(['openai/gpt-6.1-terra'])
      expect(attachment.reload.meta).to include('image_recognition_reader' => 'handwriting', 'image_recognition_model' => 'openai/gpt-6.1-terra')
    end
  end

  context 'with a probability just below the threshold (0.29)' do
    let(:router_probability) { 0.29 }

    it 'is still an ordinary image' do
      service.perform

      expect(chats_sent.first['model']).to eq('google/gemini-3.1-flash-lite')
    end
  end

  context 'when the router does not answer' do
    let(:router_status) { 503 }

    it 'reads with Terra, and says so in the llm_event', :aggregate_failures do
      expect(service.perform).to eq('Квитанция 12 000')

      expect(chats_sent.first['model']).to eq('openai/gpt-6.1-terra')
      event = LlmEvent.find_by!(account_id: account.id, event_name: 'captain.image.read')
      expect(event.payload).to include('reader' => 'handwriting', 'router_status' => 'failed')
      expect(event.payload).not_to have_key('router_probability')
    end
  end

  context 'with the platform settings changed' do
    it 'reads with the models of the settings, the same for every account', :aggregate_failures do
      upsert_installation_config('CAPTAIN_IMAGE_RECOGNITION_MODEL', 'openai/gpt-6-luna')
      upsert_installation_config('CAPTAIN_IMAGE_ROUTER_MODEL', 'perplexity/pplx-decider-flash-v1.2')

      service.perform

      expect(decisions_sent.first['model']).to eq('perplexity/pplx-decider-flash-v1.2')
      expect(chats_sent.first['model']).to eq('openai/gpt-6-luna')
      expect(chats_sent.first['provider']).to include('only' => %w[openai azure])
    end

    it 'does not follow the default model of the installation' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-5.6-luna')

      service.perform

      expect(chats_sent.first['model']).to eq('google/gemini-3.1-flash-lite')
    end
  end

  context 'with an external link and no file' do
    let(:attachment) { message.attachments.create!(account: account, file_type: :image, external_url: 'https://cdn.example.org/p/9f3a1c') }
    let(:service) { described_class.new(account: account, attachment: attachment, image_url: attachment.external_url) }
    let(:with_file) { false }

    before do
      tempfile = Tempfile.new(['p', '.jpg'], binmode: true)
      tempfile.write(image_bytes)
      tempfile.rewind
      result = SafeFetch::Result.new(tempfile: tempfile, filename: 'p', content_type: 'image/jpeg')
      allow(SafeFetch).to receive(:fetch).and_yield(result)
    end

    it 'fetches the link once itself and never hands it to a provider', :aggregate_failures do
      expect(service.perform).to eq('Квитанция 12 000')

      expect(SafeFetch).to have_received(:fetch).once
                                                .with('https://cdn.example.org/p/9f3a1c', hash_including(allowed_content_type_prefixes: ['image/']))
      expect(chats_sent.to_json).not_to include('cdn.example.org')
      expect(decisions_sent.to_json).not_to include('cdn.example.org')
    end
  end

  context 'with a file that is not an image' do
    it 'answers with the note that recognition is unavailable and asks nobody', :aggregate_failures do
      attachment.file.attach(io: StringIO.new("%PDF-1.4\n"), filename: 'doc.pdf', content_type: 'application/pdf')

      expect(service.perform).to eq(described_class::FALLBACK_DESCRIPTION)
      expect(decisions_sent).to be_empty
      expect(chats_sent).to be_empty
    end
  end
end
