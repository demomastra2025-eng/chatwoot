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
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:response) { instance_double(RubyLLM::Message, content: 'Screenshot with an order error') }
  let(:service) { described_class.new(account: account, attachment: attachment, image_url: attachment.external_url) }

  before do
    allow(service).to receive(:model).and_return('gpt-5.4-mini')
    allow(Llm::Config).to receive(:provider_for_model).with('gpt-5.4-mini', account: account).and_return('openai')
    allow(service).to receive(:chat).with(model: 'gpt-5.4-mini', temperature: 0).and_return(chat)
  end

  it 'recognizes an image through the configured image recognition model and caches the result' do
    expect(Llm::ChatClient).to receive(:ask) do |received_chat, content, observability:, account:, model:|
      expect(received_chat).to eq(chat)
      expect(account).to eq(service.account)
      expect(model).to eq('gpt-5.4-mini')
      expect(content).to be_a(RubyLLM::Content)
      expect(content.text).to include('Describe the attached customer-shared image')
      expect(content.attachments.first.source.to_s).to eq('https://example.com/image.jpg')
      expect(observability).to include(runtime_mode: 'image_recognition', feature_name: 'image_recognition')
      response
    end

    expect(service.perform).to eq('Screenshot with an order error')
    expect(attachment.reload.meta).to include('image_recognition_description' => 'Screenshot with an order error')
  end

  it 'uses cached image recognition without calling the model' do
    attachment.update!(meta: { 'image_recognition_description' => 'Cached image description' })

    expect(Llm::ChatClient).not_to receive(:ask)

    expect(service.perform).to eq('Cached image description')
  end

  it 'returns a safe fallback when no image recognition model is available' do
    allow(service).to receive(:model).and_return(nil)

    expect(Llm::ChatClient).not_to receive(:ask)

    expect(service.perform).to eq('User shared an image, but image recognition is temporarily unavailable.')
  end
end
