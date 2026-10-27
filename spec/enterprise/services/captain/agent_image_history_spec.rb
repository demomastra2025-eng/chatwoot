require 'rails_helper'

# The agent (a reply suggestion, a live run, a council part) never receives an image: not its bytes and not a link to it. It reads the
# text of the image, said to be an automatic description. PROD 27.10: a link in the prompt cost a provider a fetch at every step of a
# run (about 4 s each), and the history restorer downloaded the image to learn its type (0.6-1.1 s per chat build).
RSpec.describe 'The images in the history of an agent' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:label) { 'Image attachment (automatic description, it may be inaccurate)' }
  # A link whose path says nothing of the type: RubyLLM would have to download the image to learn it.
  let(:link) { 'https://files.example.org/media/9f3a1c' }
  let!(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Вот направление')
  end
  let!(:attachment) do
    message.attachments.create!(
      account_id: account.id, file_type: :image, external_url: link,
      meta: { 'image_recognition_description' => 'Направление на УЗИ от 12.10, подпись неразборчиво' }
    )
  end

  # The chat the runtime builds: every history entry goes through the library that restores messages.
  def restored_messages(history)
    chat = Struct.new(:messages) do
      def add_message(message) = messages << message
    end.new([])
    Captain::Runtime::HistoryRestorer.restore(chat, history)
    chat.messages
  end

  def assert_text_only(messages)
    expect(messages).not_to be_empty
    messages.each do |chat_message|
      content = chat_message.content
      expect(content).to be_a(String).or(satisfy { |value| value.is_a?(RubyLLM::Content) && value.attachments.empty? })
    end
  end

  before { stub_request(:any, /files\.example\.org/).to_return(status: 200, body: 'image bytes', headers: { 'Content-Type' => 'image/jpeg' }) }

  context 'when a reply suggestion builds the history' do
    let(:history) { Captain::ReplySuggestion::HistoryBuilder.new(account: account, conversation: conversation, assistant: assistant).perform }

    it 'gives the agent the automatic description and no image part' do
      content = history.last[:content]
      parts = Array(content)

      expect(parts.map { |part| part[:type] }.uniq).to eq(['text'])
      expect(parts.pluck(:text)).to include("#{label}: Направление на УЗИ от 12.10, подпись неразборчиво")
      expect(history.to_json).not_to include(link)
    end

    it 'restores the chat without any attachment and without downloading the image to learn its type' do
      messages = restored_messages(history)

      assert_text_only(messages)
      expect(messages.map { |chat_message| chat_message.content.respond_to?(:text) ? chat_message.content.text : chat_message.content }.join)
        .to include('Направление на УЗИ от 12.10')
      expect(a_request(:any, /files\.example\.org/)).not_to have_been_made
    end
  end

  context 'when a live run builds the history' do
    it 'gives the agent the automatic description and no image part, whatever the budget of images' do
      budget = Captain::Conversation::HistoryBudget.new
      content = Captain::OpenAiMessageBuilderService.new(message: message, assistant: assistant, budget: budget).generate_content

      expect(Array(content).pluck(:type).uniq).to eq(['text'])
      expect(Array(content).pluck(:text)).to include("#{label}: Направление на УЗИ от 12.10, подпись неразборчиво")
      assert_text_only(restored_messages([{ role: 'user', content: content }]))
      expect(a_request(:any, /files\.example\.org/)).not_to have_been_made
    end

    it 'describes an image that has no description yet, once, and still sends only text' do
      attachment.update!(meta: {})
      recognition = instance_double(Captain::ImageRecognitionService, perform: 'Чек на 4 500')
      allow(Captain::ImageRecognitionService).to receive(:new).and_return(recognition)

      content = Captain::OpenAiMessageBuilderService.new(message: message, assistant: assistant, budget: Captain::Conversation::HistoryBudget.new)
                                                    .generate_content

      expect(recognition).to have_received(:perform).once
      expect(Array(content).pluck(:text)).to include("#{label}: Чек на 4 500")
      assert_text_only(restored_messages([{ role: 'user', content: content }]))
    end
  end

  context 'when the campaign or reminder writer builds the history' do
    it 'gives the same text and no image part' do
      content = Captain::OpenAiMessageBuilderService.new(message: message, assistant: assistant).generate_content

      expect(Array(content).pluck(:type).uniq).to eq(['text'])
      expect(content.to_json).not_to include(link)
    end
  end
end
