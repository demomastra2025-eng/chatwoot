# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::CommunicationThreadResolver do
  describe '#perform' do
    let(:account) do
      create(:account).tap { |record| record.enable_features!('communication_threads') }
    end

    it 'creates a communication thread and links the conversation', :aggregate_failures do
      conversation = create(:conversation, account: account, status: :open, priority: :high)

      thread = described_class.new(conversation: conversation).perform

      expect(thread).to be_persisted
      expect(thread.account).to eq(conversation.account)
      expect(thread.contact).to eq(conversation.contact)
      expect(thread.status).to eq(conversation.status)
      expect(thread.priority).to eq(conversation.priority)
      expect(thread.communication_thread_conversations.count).to eq(1)

      link = thread.communication_thread_conversations.first
      expect(link.conversation).to eq(conversation)
      expect(link.inbox).to eq(conversation.inbox)
      expect(link.contact_inbox).to eq(conversation.contact_inbox)
      expect(link).to be_primary
      expect(conversation.reload.communication_thread).to eq(thread)
    end

    it 'resolves a persisted conversation whose trigger-populated attributes are dirty' do
      conversation = create(:conversation, account: account)
      conversation.display_id_will_change!

      expect { described_class.new(conversation: conversation).perform }.not_to raise_error
      expect(conversation.reload.communication_thread).to be_present
    end

    it 'reuses the existing contact thread across different inbox conversations' do
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: contact, inbox: second_inbox)
      second_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: second_inbox,
        contact_inbox: second_contact_inbox
      )

      first_thread = described_class.new(conversation: first_conversation).perform
      second_thread = described_class.new(conversation: second_conversation).perform

      expect(second_thread).to eq(first_thread)
      expect(first_thread.conversations).to contain_exactly(first_conversation, second_conversation)
      expect(first_thread.communication_thread_conversations.where(primary: true).count).to eq(1)
    end

    it 'uses the same advisory lock for different conversations of one contact' do
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      connection = ActiveRecord::Base.connection
      lock_statements = []
      allow(connection).to receive(:execute).and_wrap_original do |original, statement, *args|
        lock_statements << statement if statement.include?('pg_advisory_xact_lock')
        original.call(statement, *args)
      end

      described_class.new(conversation: first_conversation).perform
      described_class.new(conversation: second_conversation).perform

      expect(lock_statements.size).to eq(2)
      expect(lock_statements.uniq.size).to eq(1)
      expect(CommunicationThread.where(account: account, contact: contact).count).to eq(1)
    end

    it 'locks the conversation row before taking the contact advisory lock' do
      conversation = create(:conversation, account: account)
      lock_queries = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        lock_queries << :conversation if sql.end_with?('FOR UPDATE')
        lock_queries << :contact if sql.include?('pg_advisory_xact_lock')
      end

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.new(conversation: conversation).perform
      end

      expect(lock_queries).to include(:conversation, :contact)
      expect(lock_queries.index(:conversation)).to be < lock_queries.index(:contact)
    end

    it 'is idempotent for the same conversation' do
      conversation = create(:conversation, account: account)

      first_thread = described_class.new(conversation: conversation).perform
      second_thread = described_class.new(conversation: conversation).perform

      expect(second_thread).to eq(first_thread)
      expect(CommunicationThread.count).to eq(1)
      expect(CommunicationThreadConversation.count).to eq(1)
    end

    it 'rejects a malformed conversation linked to a contact from another account' do
      conversation = create(:conversation, account: account)
      foreign_account = create(:account)
      foreign_contact = create(:contact, account: foreign_account)
      foreign_contact_inbox = create(:contact_inbox, contact: foreign_contact, inbox: conversation.inbox)

      # rubocop:disable Rails/SkipsModelValidations
      conversation.update_columns(contact_id: foreign_contact.id, contact_inbox_id: foreign_contact_inbox.id)
      # rubocop:enable Rails/SkipsModelValidations

      expect(described_class.new(conversation: conversation.reload).perform).to be_nil
      expect(CommunicationThread.where(account: account, contact: foreign_contact)).to be_empty
    end

    it 'does not reuse a linked thread whose account no longer matches the conversation' do
      conversation = create(:conversation, account: account)
      foreign_account = create(:account)
      original_thread = described_class.new(conversation: conversation).perform

      # rubocop:disable Rails/SkipsModelValidations
      original_thread.update_column(:account_id, foreign_account.id)
      # rubocop:enable Rails/SkipsModelValidations

      conversation.reload
      expect(conversation.communication_thread).to be_nil
      current_thread = described_class.new(conversation: conversation).perform

      expect(current_thread).not_to eq(original_thread)
      expect(current_thread).to have_attributes(account_id: account.id, contact_id: conversation.contact_id)
      expect(conversation.reload.communication_thread).to eq(current_thread)
      expect(original_thread.reload.account_id).to eq(foreign_account.id)
    end

    it 'moves a conversation to the thread for the current contact', :aggregate_failures do
      old_contact = create(:contact, account: account)
      old_inbox = create(:inbox, account: account)
      old_contact_inbox = create(:contact_inbox, contact: old_contact, inbox: old_inbox)
      moved_conversation = create(
        :conversation,
        account: account,
        contact: old_contact,
        inbox: old_inbox,
        contact_inbox: old_contact_inbox
      )
      remaining_conversation = create(:conversation, account: account, contact: old_contact)
      old_thread = described_class.new(conversation: moved_conversation).perform
      described_class.new(conversation: remaining_conversation).perform
      new_contact = create(:contact, account: account)
      new_contact_inbox = create(:contact_inbox, contact: new_contact, inbox: old_inbox)

      # rubocop:disable Rails/SkipsModelValidations
      moved_conversation.update_columns(
        contact_id: new_contact.id,
        contact_inbox_id: new_contact_inbox.id,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations

      new_thread = described_class.new(conversation: moved_conversation.reload).perform

      expect(new_thread).not_to eq(old_thread)
      expect(new_thread.contact).to eq(new_contact)
      expect(new_thread.conversations).to contain_exactly(moved_conversation)
      expect(old_thread.reload.conversations).to contain_exactly(remaining_conversation)
      primary_links = old_thread.communication_thread_conversations.where(primary: true)
      expect(primary_links.count).to eq(1)
      expect(moved_conversation.reload.communication_thread).to eq(new_thread)
    end

    it 'refreshes aggregate fields from linked conversations', :aggregate_failures do
      contact = create(:contact, :with_email, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      latest_activity_at = 2.minutes.ago

      create(
        :message,
        account: account,
        conversation: first_conversation,
        inbox: first_conversation.inbox,
        sender: contact,
        created_at: 1.day.ago
      )
      create(
        :message,
        account: account,
        conversation: second_conversation,
        inbox: second_conversation.inbox,
        sender: contact,
        created_at: latest_activity_at
      )

      # rubocop:disable Rails/SkipsModelValidations
      first_conversation.update_columns(
        status: Conversation.statuses[:resolved],
        priority: Conversation.priorities[:low],
        last_activity_at: 1.day.ago,
        agent_last_seen_at: 2.days.ago,
        updated_at: Time.current
      )
      second_conversation.update_columns(
        status: Conversation.statuses[:pending],
        priority: Conversation.priorities[:urgent],
        last_activity_at: latest_activity_at,
        agent_last_seen_at: 2.days.ago,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations

      thread = described_class.new(conversation: second_conversation.reload).perform

      expect(thread.status).to eq('pending')
      expect(thread.priority).to eq('urgent')
      expect(thread.last_activity_at).to be_within(1.second).of(latest_activity_at)
      expect(thread.unread_count).to eq(2)
    end

    # One person, one status: the most urgent status of the channels wins (open > pending > snoozed > resolved), whichever
    # conversation was saved last. The merge of the open dialogs is switched off, so every combination can be built.
    describe 'the one status of a person' do
      statuses_by_combination = [
        [%w[open resolved], 'open'],
        [%w[open snoozed], 'open'],
        [%w[open pending], 'open'],
        [%w[open pending snoozed resolved], 'open'],
        [%w[pending snoozed], 'pending'],
        [%w[pending resolved], 'pending'],
        [%w[snoozed resolved], 'snoozed'],
        [%w[snoozed snoozed], 'snoozed'],
        [%w[resolved resolved], 'resolved'],
        [%w[open], 'open'],
        [%w[snoozed], 'snoozed'],
        [%w[resolved], 'resolved']
      ]

      def person_channel(contact)
        inbox = create(:inbox, account: account)
        create(:conversation, account: account, contact: contact, inbox: inbox,
                              contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox), status: :resolved)
      end

      def saved_minutes_ago(status, index, urgent_saved_last)
        urgencies = Conversations::CommunicationThreadResolver::STATUS_URGENCY
        urgency = urgencies.index(status)
        ((urgent_saved_last ? urgency : urgencies.size - urgency) * 10) + index
      end

      # urgent_saved_last: true saves the most urgent channel last (the old rule would pick it), false saves it first (the
      # old rule would pick a quieter channel). Either way the person must get the most urgent status. The channels are built
      # resolved and moved afterwards, so the merge of the open dialogs does not see them one by one.
      def build_person(statuses, urgent_saved_last:)
        contact = create(:contact, account: account)
        conversations = statuses.map { person_channel(contact) }
        conversations.zip(statuses).each_with_index do |(conversation, status), index|
          conversation.update_columns(status: Conversation.statuses.fetch(status), # rubocop:disable Rails/SkipsModelValidations
                                      updated_at: saved_minutes_ago(status, index, urgent_saved_last).minutes.ago)
        end
        described_class.new(conversation: conversations.first.reload, enforce_single_open_dialog: false).perform
      end

      saved_orders = [true, false]

      statuses_by_combination.each do |statuses, expected|
        saved_orders.each do |urgent_saved_last|
          it "gives #{statuses.join(' + ')} the status #{expected} (most urgent channel saved #{urgent_saved_last ? 'last' : 'first'})" do
            thread = build_person(statuses, urgent_saved_last: urgent_saved_last)

            expect(thread.status).to eq(expected)
          end
        end
      end

      it 'does not repaint the person when the priority of a quiet channel changes', :aggregate_failures do
        thread = build_person(%w[open snoozed resolved], urgent_saved_last: false)
        quiet_channel = thread.conversations.find(&:snoozed?)
        expect(thread.status).to eq('open')

        quiet_channel.update!(priority: :urgent)

        expect(quiet_channel.reload.communication_thread.status).to eq('open')
        expect(thread.reload).to have_attributes(status: 'open', priority: 'urgent')
      end

      it 'wakes the whole person through the conversation that receives a message', :aggregate_failures do
        thread = build_person(%w[snoozed snoozed], urgent_saved_last: false)
        woken, sleeping = thread.conversations.order(:id).to_a
        expect(thread.status).to eq('snoozed')

        create(:message, conversation: woken, account: account, inbox: woken.inbox, message_type: :incoming, sender: thread.contact,
                         content: 'Are you there?')

        expect(woken.reload).to be_open
        expect(sleeping.reload).to be_resolved
        expect(sleeping.status_transitions.pluck(:to_status, :source)).to eq([%w[resolved system]])
        expect(thread.reload.status).to eq('open')
      end
    end
  end

  describe '.front_conversation' do
    let(:account) { create(:account) }
    let(:contact) { create(:contact, account: account) }
    let(:thread) { create(:communication_thread, account: account, contact: contact) }

    def linked_conversation(status)
      create(:conversation, account: account, contact: contact, inbox: create(:inbox, account: account), status: status).tap do |conversation|
        create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
      end
    end

    it 'is the conversation whose status the thread shows, not the newest one, and nil without a thread' do
      open = linked_conversation(:open)
      linked_conversation(:resolved)

      expect(described_class.front_conversation(thread)).to eq(open)
      expect(described_class.front_conversation(nil)).to be_nil
    end

    it 'is the conversation of the latest activity when every conversation is resolved' do
      older = linked_conversation(:resolved)
      newer = linked_conversation(:resolved)
      older.update_columns(last_activity_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
      newer.update_columns(last_activity_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.front_conversation(thread)).to eq(older)
    end
  end
end
