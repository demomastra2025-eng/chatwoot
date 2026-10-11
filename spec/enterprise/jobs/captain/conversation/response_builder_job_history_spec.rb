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
end
