require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::HistoryBuilder do
  subject(:history) { described_class.new(account: account, conversation: conversation).perform }

  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account, inbox: create(:inbox, account: account)) }

  def add_message(type, content, **attributes)
    create(:message, conversation: conversation, account: account, message_type: type, content: content, **attributes)
  end

  def add_image(message, name)
    message.attachments.create!(account_id: account.id, file_type: :image, external_url: "https://example.com/#{name}.jpg")
  end

  it 'gives the messages in order with the role and the send time of each, and the name of the agent that wrote an answer' do
    question = add_message(:incoming, 'Нужен ЛОР')
    answer = add_message(:outgoing, 'Какой день?', additional_attributes: { 'agent_name' => 'Сезім' })
    day = add_message(:incoming, 'Завтра')
    add_message(:incoming, 'Заметка', private: true)

    expect(history).to eq(
      [
        { content: 'Нужен ЛОР', role: 'user', sent_at: question.reload.created_at },
        { content: 'Какой день?', role: 'assistant', agent_name: 'Сезім', sent_at: answer.reload.created_at },
        { content: 'Завтра', role: 'user', sent_at: day.reload.created_at }
      ]
    )
  end

  # The runner writes each message after its send time and tells the model when the message being answered was sent: a suggestion
  # asked on Monday for a patient's Saturday "tomorrow" reads Sunday, not Tuesday.
  it 'keeps the Saturday send time of a message that is answered on Monday' do
    saturday = Time.find_zone('Asia/Almaty').local(2026, 10, 24, 9, 50)
    add_message(:incoming, 'Я записан на 10:10 завтра?', created_at: saturday)

    travel_to(Time.find_zone('Asia/Almaty').local(2026, 10, 26, 9, 0)) do
      expect(history.last).to include(content: 'Я записан на 10:10 завтра?', role: 'user', sent_at: saturday)
    end
  end

  # Suggestion eval 27.10 (c76-1205215, c78-1186457): the operator's voice notes had no transcript, so the agent saw "Message without
  # content", did not know that the time was agreed, and started the booking again when the patient wrote «Принял / Буду».
  describe 'the voice notes' do
    def add_voice_note(type, transcript: nil)
      message = add_message(type, nil)
      attachment = message.attachments.create!(account_id: account.id, file_type: :audio, external_url: 'https://example.com/voice.ogg')
      attachment.update!(meta: { 'transcribed_text' => transcript }) if transcript
      message
    end

    before { account.update!(audio_transcriptions: true) }

    it 'gives the transcript of a voice note of the staff as the text of its message, as it does for a patient' do
      add_voice_note(:outgoing, transcript: 'Записал вас на завтра в 14:00')
      add_voice_note(:incoming, transcript: 'Принял, буду')

      expect(history.pluck(:content, :role)).to eq([['Записал вас на завтра в 14:00', 'assistant'], ['Принял, буду', 'user']])
    end

    it 'says that a voice note without a transcript exists and that its words are not available, for the staff and for the patient' do
      add_voice_note(:outgoing)
      add_voice_note(:incoming)

      expect(history.pluck(:content)).to eq([described_class::STAFF_VOICE_NOTE, described_class::PATIENT_VOICE_NOTE])
      expect(described_class::STAFF_VOICE_NOTE).to include('a staff member', 'its words are not available to you')
      expect(described_class::STAFF_VOICE_NOTE).not_to include('clinic')
    end

    it 'keeps the placeholder for a message with nothing in it' do
      add_message(:incoming, nil)

      expect(history.pluck(:content)).to eq([Captain::OpenAiMessageBuilderService::EMPTY_CONTENT])
    end
  end

  it 'asks for a reply in general when the conversation has no message of the customer' do
    add_message(:outgoing, 'Здравствуйте!')

    expect(history.last).to eq(role: 'user', content: described_class::FALLBACK_USER_PROMPT)
  end

  it 'keeps only the latest messages the AI reads: the limit is the same for every agent' do
    stub_const('Captain::Assistant::HISTORY_MESSAGE_LIMIT', 2)
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
      entry[:content].filter_map { |part| part[:text] if part[:type] == 'text' && part[:text].start_with?('Image attachment') }
    end

    def automatic(text)
      "Image attachment (automatic description, it may be inaccurate): #{text}"
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
      expect(result.flat_map { |entry| description_texts(entry) }).to eq(images.map { |image| automatic("Снимок #{image.id}") })
    end

    it 'sends the description of every image and the pixels or a link of none' do
      describer = instance_double(Captain::ReplySuggestion::ImageDescriber, perform: images.to_h { |image| [image.id, "Снимок #{image.id}"] })
      allow(Captain::ReplySuggestion::ImageDescriber).to receive(:new).and_return(describer)

      first, second, third = history

      expect([first, second, third].map { |entry| image_parts(entry).size }).to eq([0, 0, 0])
      expect([first, second, third].map { |entry| description_texts(entry).size }).to eq([1, 1, 1])
      expect(history.to_json).not_to include('example.com')
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
      expect(description_texts(result.first)).to eq([automatic('Уже описано')])
    end

    it 'does not describe images when the workspace setting says the AI does not read images' do
      Captain::AccountSettings.new(account).update!('understanding' => { 'images' => false })
      expect(Captain::ReplySuggestion::ImageDescriber).not_to receive(:new)

      expect(history.pluck(:content)).to eq(['Первый снимок', 'Второй снимок', 'Третий снимок'])
    end
  end
end
