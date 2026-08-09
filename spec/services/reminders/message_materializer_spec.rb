require 'rails_helper'

RSpec.describe Reminders::MessageMaterializer do
  describe '#perform' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:sender) { create(:user, account: account) }
    let(:reminder) { create(:reminder, account: account, creator: sender, owner: sender) }

    it 'persists retained touch files on the materialized conversation message' do
      reminder.files.attach(
        io: StringIO.new('touch attachment'),
        filename: 'touch.txt',
        content_type: 'text/plain'
      )

      message = described_class.new(reminder: reminder).perform(
        conversation: conversation,
        sender: sender,
        content: 'Follow-up'
      )

      attachment = message.reload.attachments.sole
      expect(attachment.file).to be_attached
      expect(attachment.file.filename.to_s).to eq('touch.txt')
      expect(reminder.reload.metadata[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY]).to eq(message.id)
    end
  end
end
