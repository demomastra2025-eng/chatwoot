require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:assistant) { create(:captain_assistant, account: account, config: { 'history_message_limit' => 0 }) }

  def history
    job = described_class.new
    job.instance_variable_set(:@conversation, conversation)
    job.instance_variable_set(:@assistant, assistant)
    job.instance_variable_set(:@input_assistant, assistant)
    job.send(:collect_previous_messages)
  end

  it 'keeps the latest incoming message and its quoted message beyond the 40-message and text budgets' do
    quoted = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :outgoing, content: 'Original quoted answer')
    42.times do |index|
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, content: "Older message #{index} #{'x' * 500}")
    end
    latest = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :incoming, content: 'Latest customer question')
    latest.update!(content_attributes: { 'in_reply_to' => quoted.id })

    contents = history.map { |entry| entry[:content] }

    expect(contents).to include('Original quoted answer', 'Latest customer question')
    expect(contents.size).to be <= 41
    expect(contents.join.bytesize).to be <= Captain::Conversation::HistoryBudget::MAX_TEXT_BYTES
  end

  # A transcription of a lab page is 2-5 KB. Before the images were described by text only, an image was one line or an image part.
  context 'with images whose descriptions are long' do
    let(:long_text) { ('Гемоглобин 134 г/л, эритроциты 4,98 x10^12/л, лейкоциты 6,2. ' * 58).strip }

    def customer_message(content, description: nil)
      message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: content)
      message.attachments.create!(
        account_id: account.id, file_type: :image, external_url: 'https://files.example.org/m/1',
        meta: { 'image_recognition_description' => description }
      )
      message
    end

    def texts(entry)
      Array(entry[:content]).map { |part| part.is_a?(Hash) ? part[:text] : part }
    end

    before do
      6.times do |index|
        create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                         content: "Dialogue #{index} #{'d' * 2_000}")
      end
      3.times { |index| customer_message("Photo #{index}", description: "#{index} #{long_text}") }
    end

    it 'keeps all the dialogue and the words of the customer next to the images' do
      all_text = history.flat_map { |entry| texts(entry) }.join(' | ')

      6.times { |index| expect(all_text).to include("Dialogue #{index} ") }
      3.times { |index| expect(all_text).to include("Photo #{index}") }
    end

    it 'gives the newest image its whole text, an older one what is left, and the oldest a note that its text is left out' do
      images = history.last(3).map { |entry| texts(entry).grep(/\AImage attachment/).join }

      expect(images.last).to end_with("2 #{long_text}")
      expect(images[1]).to end_with(Captain::Conversation::HistoryBudget::IMAGE_CUT_MARK)
      expect(images.first).to eq(Captain::ImageReading::Prompt::IMAGE_LEFT_OUT)
    end

    it 'spends no more on the text of images than the budget of the images' do
      label = Captain::ImageReading::Prompt.agent_text('').bytesize
      lines = history.flat_map { |entry| texts(entry) }.grep(/\AImage attachment \(automatic/)
      spent = lines.sum { |line| line.bytesize - label }

      expect(lines.size).to eq(2)
      expect(spent).to be <= Captain::Conversation::HistoryBudget::MAX_IMAGE_BYTES
    end
  end
end
