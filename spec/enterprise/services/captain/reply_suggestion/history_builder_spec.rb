require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::HistoryBuilder do
  subject(:history) { described_class.new(account: account, conversation: conversation, assistant: assistant).perform }

  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account, inbox: create(:inbox, account: account)) }
  let(:assistant) { create(:captain_assistant, account: account, active: true) }

  def add_message(type, content, **attributes)
    create(:message, conversation: conversation, account: account, message_type: type, content: content, **attributes)
  end

  def add_image(message, name)
    message.attachments.create!(account_id: account.id, file_type: :image, external_url: "https://example.com/#{name}.jpg")
  end

  it 'gives the messages in the order of the conversation with the role of each, and the name of the agent that wrote an answer' do
    add_message(:incoming, 'Нужен ЛОР')
    add_message(:outgoing, 'Какой день?', additional_attributes: { 'agent_name' => 'Сезім' })
    add_message(:incoming, 'Завтра')
    add_message(:incoming, 'Заметка', private: true)

    expect(history).to eq(
      [
        { content: 'Нужен ЛОР', role: 'user' },
        { content: 'Какой день?', role: 'assistant', agent_name: 'Сезім' },
        { content: 'Завтра', role: 'user' }
      ]
    )
  end

  it 'asks for a reply in general when the conversation has no message of the customer' do
    add_message(:outgoing, 'Здравствуйте!')

    expect(history.last).to eq(role: 'user', content: described_class::FALLBACK_USER_PROMPT)
  end

  it 'keeps only the latest messages the assistant is set to read' do
    allow(assistant).to receive(:history_message_limit_value).and_return(2)
    %w[первое второе третье].each { |text| add_message(:incoming, text) }

    expect(history.pluck(:content)).to eq(%w[второе третье])
  end

  describe 'the images' do
    let!(:old_message) { add_message(:incoming, 'Первый снимок') }
    let!(:middle_message) { add_message(:incoming, 'Второй снимок') }
    let!(:new_message) { add_message(:incoming, 'Третий снимок') }
    let!(:images) { [add_image(old_message, 'a'), add_image(middle_message, 'b'), add_image(new_message, 'c')] }

    def image_parts(entry)
      entry[:content].select { |part| part[:type] == 'image_url' }
    end

    def description_texts(entry)
      entry[:content].filter_map { |part| part[:text] if part[:type] == 'text' && part[:text].start_with?('Image attachment:') }
    end

    it 'describes every image of the history, in one go, and never inside the builder of a message' do
      expect(Captain::ImageRecognitionService).not_to receive(:new)
      describer = instance_double(Captain::ReplySuggestion::ImageDescriber, perform: images.to_h { |image| [image.id, "Снимок #{image.id}"] })
      allow(Captain::ReplySuggestion::ImageDescriber).to receive(:new).and_return(describer)

      result = history

      expect(Captain::ReplySuggestion::ImageDescriber).to have_received(:new).once
      expect(Captain::ReplySuggestion::ImageDescriber).to have_received(:new).with(
        account: account, targets: images.map { |image| [image, image.external_url] }
      )
      expect(result.flat_map { |entry| description_texts(entry) }).to eq(images.map { |image| "Image attachment: Снимок #{image.id}" })
    end

    it 'sends the pixels of the newest images only, and the description of all of them' do
      describer = instance_double(Captain::ReplySuggestion::ImageDescriber, perform: images.to_h { |image| [image.id, "Снимок #{image.id}"] })
      allow(Captain::ReplySuggestion::ImageDescriber).to receive(:new).and_return(describer)

      first, second, third = history

      expect([first, second, third].map { |entry| image_parts(entry).size }).to eq([0, 1, 1])
      expect([first, second, third].map { |entry| description_texts(entry).size }).to eq([1, 1, 1])
    end

    it 'describes the images in parallel through the real describer and reuses the descriptions already cached' do
      images.first.update!(meta: { Captain::ImageRecognitionService::CACHE_KEY => 'Уже описано' })
      calls = Concurrent::Array.new
      allow(Captain::ImageRecognitionService).to receive(:new) do |attachment:, **|
        instance_double(Captain::ImageRecognitionService).tap do |recognition|
          allow(recognition).to receive(:perform) do
            calls << attachment.id
            "Новое #{attachment.id}"
          end
        end
      end

      result = history

      expect(calls).to match_array(images.last(2).map(&:id))
      expect(description_texts(result.first)).to eq(['Image attachment: Уже описано'])
    end

    it 'does not describe images when the assistant does not read images' do
      allow(assistant).to receive(:account_settings).and_return(instance_double(Captain::AccountSettings, section: { 'images' => false }))
      expect(Captain::ReplySuggestion::ImageDescriber).not_to receive(:new)

      expect(history.pluck(:content)).to eq(['Первый снимок', 'Второй снимок', 'Третий снимок'])
    end
  end
end
