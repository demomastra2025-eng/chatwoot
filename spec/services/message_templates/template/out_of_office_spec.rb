require 'rails_helper'

describe MessageTemplates::Template::OutOfOffice do
  context 'when this hook is called' do
    let(:conversation) { create(:conversation) }

    before do
      conversation.inbox.account.update!(workspace_working_hours: AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.map do |day|
        day.merge('closed_all_day' => true)
      end,
                                         workspace_out_of_office: { enabled: true, message: 'We are unavailable' })
    end

    it 'creates the out of office messages' do
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.template.count).to eq(1)
      expect(conversation.messages.template.first.content).to eq(conversation.inbox.workspace_out_of_office_message)
    end

    it 'creates the out of office messages with template variable' do
      conversation.inbox.account.update!(workspace_out_of_office: { enabled: true,
                                                                    message: 'Hey, {{contact.name}} we are unavailable at the moment.' })
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.count).to eq(1)
      expect(conversation.messages.last.content).to eq("Hey, #{conversation.contact.name} we are unavailable at the moment.")
    end

    it 'creates the out of office messages with more than one variable strings' do
      conversation.inbox.account.update!(workspace_out_of_office: {
                                           enabled: true,
                                           message: 'Hey, {{contact.name}} we are unavailable at the moment. - from {{account.name}}'
                                         })
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.count).to eq(1)
      expect(conversation.messages.last.content).to eq(
        "Hey, #{conversation.contact.name} we are unavailable at the moment. - from #{conversation.account.name}"
      )
    end
  end
end
