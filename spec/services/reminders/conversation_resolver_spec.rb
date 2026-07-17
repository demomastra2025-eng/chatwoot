require 'rails_helper'

RSpec.describe Reminders::ConversationResolver do
  describe '#perform' do
    it 'raises a non-retryable error when the target cannot be routed to the inbox' do
      inbox = instance_double(Inbox)
      contact = instance_double(Contact)
      reminder = instance_double(
        Reminder,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: nil,
        target_inbox: inbox,
        target_contact: contact
      )
      resolver = instance_double(Outbound::ContactInboxResolver, perform: nil)

      allow(Outbound::ContactInboxResolver).to receive(:new).with(inbox: inbox, contact: contact).and_return(resolver)

      expect { described_class.new(reminder: reminder).perform }
        .to raise_error(Reminders::UndeliverableTargetError, 'Touch target is not deliverable for this inbox')
    end
  end
end
