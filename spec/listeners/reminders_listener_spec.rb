require 'rails_helper'

RSpec.describe RemindersListener do
  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:other_conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  describe '#message_created' do
    it 'auto-cancels only explicitly flagged touches in the current conversation after a customer incoming reply' do
      current_touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        body: 'Current conversation touch',
        metadata: { 'auto_cancel_on_incoming_explicit' => true }
      )
      other_conversation_touch = create(
        :reminder,
        account: account,
        touch_conversation: other_conversation,
        conversation: other_conversation,
        remindable: other_conversation,
        auto_cancel_on_incoming: true,
        body: 'Other conversation touch',
        metadata: { 'auto_cancel_on_incoming_explicit' => true }
      )
      implicit_touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        body: 'Implicit auto cancel touch',
        metadata: {}
      )
      recurring_future_touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        repeat_mode: :daily,
        body: 'Recurring future touch',
        metadata: { 'auto_cancel_on_incoming_explicit' => true }
      )
      explicit_false_touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        body: 'Explicitly keep scheduled touch',
        metadata: { 'auto_cancel_on_incoming_explicit' => false }
      )
      invalid_metadata_touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        body: 'Invalid metadata should fail closed',
        metadata: { 'auto_cancel_on_incoming_explicit' => 'yes' }
      )
      message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, sender: contact)
      event = Events::Base.new('message_created', Time.zone.now, message: message)

      listener.message_created(event)

      expect(current_touch.reload).to be_cancelled
      expect(current_touch.last_error).to eq('отменен после входящего ответа клиента')
      expect(recurring_future_touch.reload).to be_cancelled
      expect(other_conversation_touch.reload).to be_pending
      expect(implicit_touch.reload).to be_pending
      expect(explicit_false_touch.reload).to be_pending
      expect(invalid_metadata_touch.reload).to be_pending
    end

    it 'ignores private customer messages' do
      touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        body: 'Private ignored touch',
        metadata: { 'auto_cancel_on_incoming_explicit' => true }
      )
      message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        sender: contact,
        private: true
      )
      event = Events::Base.new('message_created', Time.zone.now, message: message)

      listener.message_created(event)

      expect(touch.reload).to be_pending
    end

    it 'ignores outgoing agent messages' do
      touch = create(
        :reminder,
        account: account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        auto_cancel_on_incoming: true,
        body: 'Outgoing ignored touch',
        metadata: { 'auto_cancel_on_incoming_explicit' => true }
      )
      message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :outgoing,
        sender: create(:user, account: account)
      )
      event = Events::Base.new('message_created', Time.zone.now, message: message)

      listener.message_created(event)

      expect(touch.reload).to be_pending
    end
  end

  describe '#message_updated' do
    it 'delegates provider delivery acknowledgement handling' do
      message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing)
      event = Events::Base.new('message_updated', Time.zone.now, message: message)
      service = instance_double(Reminders::PostDeliveryActionService, perform: true)

      allow(Reminders::PostDeliveryActionService).to receive(:new).with(message: message).and_return(service)

      listener.message_updated(event)

      expect(service).to have_received(:perform).once
    end
  end
end
