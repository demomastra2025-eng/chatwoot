require 'rails_helper'

RSpec.describe Labels::UnifiedAssignmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account) }
  let!(:first_conversation) { create(:conversation, account: account, contact: contact) }
  let!(:second_conversation) { create(:conversation, account: account, contact: contact) }
  let!(:third_conversation) { create(:conversation, account: account, contact: contact) }
  let(:conversations) { [first_conversation, second_conversation, third_conversation] }
  let(:dispatched) { [] }

  before do
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, *args|
      dispatched << args.first
      original.call(*args)
    end
    Current.user = user
  end

  after { Current.reset }

  describe '.add' do
    it 'writes the label to the contact and to every conversation of the person' do
      result = described_class.add(contact: contact, labels: %w[vip])

      expect(result).to eq(%w[vip])
      expect(contact.reload.label_list).to eq(%w[vip])
      expect(conversations.map { |conversation| conversation.reload.label_list.to_a }).to all(eq(%w[vip]))
    end

    it 'does not touch another person' do
      other_conversation = create(:conversation, account: account)

      described_class.add(contact: contact, labels: %w[vip])

      expect(other_conversation.reload.label_list).to be_empty
      expect(other_conversation.contact.reload.label_list).to be_empty
    end

    it 'keeps the labels that are there and does not repeat a label that differs only by case' do
      second_conversation.update_labels(%w[paid])
      contact.update_labels(%w[VIP])

      described_class.add(contact: contact, labels: %w[vip follow_up])

      expect(contact.reload.label_list).to contain_exactly('VIP', 'follow_up')
      expect(second_conversation.reload.label_list).to contain_exactly('paid', 'vip', 'follow_up')
    end

    it 'reports the change once however many conversations carry it' do
      expect { described_class.add(contact: contact, labels: %w[vip], conversation: second_conversation) }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once

      expect(dispatched.count(Events::Types::CONVERSATION_UPDATED)).to eq(1)
    end

    it 'puts the same communication thread event id on the activity message' do
      described_class.add(contact: contact, labels: %w[vip], conversation: first_conversation)

      expect(Conversations::ActivityMessageJob).to have_been_enqueued.once.with(
        first_conversation,
        hash_including(additional_attributes: { communication_thread_event_id: kind_of(String) })
      )
    end

    it 'lets the next conversation report when the source already has the label' do
      first_conversation.update_labels(%w[vip])
      dispatched.clear

      expect { described_class.add(contact: contact, labels: %w[vip], conversation: first_conversation) }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once

      expect(dispatched.count(Events::Types::CONVERSATION_UPDATED)).to eq(1)
    end

    it 'saves nothing and reports nothing when the person already has the label everywhere' do
      described_class.add(contact: contact, labels: %w[vip])
      dispatched.clear

      expect { described_class.add(contact: contact, labels: %w[vip]) }.not_to have_enqueued_job(Conversations::ActivityMessageJob)

      expect(dispatched & [Events::Types::CONVERSATION_UPDATED, Events::Types::CONTACT_UPDATED]).to be_empty
    end

    it 'writes the contact alone when the person has no conversation yet' do
      lonely = create(:contact, account: account)

      expect(described_class.add(contact: lonely, labels: %w[vip])).to eq(%w[vip])
      expect(lonely.reload.label_list).to eq(%w[vip])
    end

    it 'makes no activity message without a person acting' do
      Current.reset

      expect { described_class.add(contact: contact, labels: %w[vip]) }.not_to have_enqueued_job(Conversations::ActivityMessageJob)
      expect(first_conversation.reload.label_list).to eq(%w[vip])
    end
  end

  describe '.remove' do
    before { described_class.add(contact: contact, labels: %w[vip paid], silent: true) }

    it 'takes the label off the contact and every conversation, also a hidden one' do
      result = described_class.remove(contact: contact, labels: %w[vip], conversation: first_conversation)

      expect(result).to eq(%w[paid])
      expect(contact.reload.label_list).to eq(%w[paid])
      expect(conversations.map { |conversation| conversation.reload.label_list.to_a }).to all(eq(%w[paid]))
    end

    it 'removes a label that lives only on the contact card' do
      contact.update_labels(%w[vip paid card_only])

      described_class.remove(contact: contact, labels: %w[card_only])

      expect(contact.reload.label_list).to contain_exactly('vip', 'paid')
    end

    it 'removes a label that lives only on one conversation' do
      third_conversation.update_labels(%w[vip paid channel_only])

      described_class.remove(contact: contact, labels: %w[channel_only])

      expect(third_conversation.reload.label_list).to contain_exactly('vip', 'paid')
    end

    it 'matches the label without regard to case' do
      described_class.remove(contact: contact, labels: %w[VIP])

      expect(contact.reload.label_list).to eq(%w[paid])
    end

    it 'reports the removal once' do
      expect { described_class.remove(contact: contact, labels: %w[vip], conversation: first_conversation) }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once
    end
  end

  describe 'a card-only change' do
    before do
      account.enable_features!('communication_threads')
      contact.update_labels(%w[card_only])
      conversations.each { |conversation| conversation.reload.refresh_communication_thread! }
    end

    it 'tells the open dialog once through the thread, without a conversation event' do
      expect { described_class.remove(contact: contact, labels: %w[card_only], conversation: first_conversation) }
        .to have_enqueued_job(CommunicationThreads::RealtimeUpdateJob).once.with(
          communication_thread_id: first_conversation.reload.communication_thread.id,
          source_conversation_id: first_conversation.id,
          source_event: 'conversation.updated',
          performer_id: user.id
        )

      expect(dispatched).not_to include(Events::Types::CONVERSATION_UPDATED)
    end

    it 'leaves the thread update to the conversation event when a conversation reports the change' do
      expect { described_class.add(contact: contact, labels: %w[vip], conversation: first_conversation) }
        .to have_enqueued_job(CommunicationThreads::RealtimeUpdateJob).once
    end
  end

  # The status of the thread follows the conversation with the newest updated_at, and a label is not a change of status.
  # The older conversations are saved after the one that reports, so a write that moved updated_at put the least active
  # channel (snoozed, or pending because the assistant handles it) in front of the open one with the unanswered message.
  [%w[snoozed pending], %w[pending snoozed]].each do |older_statuses|
    describe "the status of the thread of a person with an open, a #{older_statuses.first} and a #{older_statuses.last} conversation" do
      include PersonThreadStatusHelpers

      before do
        give_person_different_statuses(first_conversation, [second_conversation, older_statuses.first],
                                       [third_conversation, older_statuses.last])
      end

      def updated_ats
        conversations.map { |conversation| conversation.reload.updated_at }
      end

      it 'stays open, in the list and in the realtime update, when a conversation reports an added label' do
        described_class.add(contact: contact, labels: %w[vip], conversation: first_conversation)

        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end

      it 'stays open when a label is removed' do
        described_class.add(contact: contact, labels: %w[vip paid], silent: true)
        give_person_different_statuses(first_conversation, [second_conversation, older_statuses.first],
                                       [third_conversation, older_statuses.last])

        described_class.remove(contact: contact, labels: %w[vip], conversation: first_conversation)

        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end

      it 'stays open when no conversation was acted on, as on the contact card and in bulk actions' do
        described_class.add(contact: contact, labels: %w[vip])

        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end

      it 'stays what it was when the label is written on the conversation that is not in front' do
        described_class.add(contact: contact, labels: %w[vip], conversation: third_conversation)

        expect(thread_status_of(first_conversation)).to eq('open')
      end

      it 'does not move the updated_at of any conversation, the source included' do
        expect { described_class.add(contact: contact, labels: %w[vip], conversation: second_conversation) }
          .not_to(change { updated_ats })
        expect { described_class.remove(contact: contact, labels: %w[vip], conversation: first_conversation) }
          .not_to(change { updated_ats })
      end

      it 'is not moved by the silent rewrite of the contact merge and the backfill, nor by the next refresh of the thread' do
        contact.update_labels(%w[card_only])

        expect { described_class.unify(contact: contact) }.not_to(change { updated_ats })

        first_conversation.reload.refresh_communication_thread!
        expect(thread_status_of(first_conversation)).to eq('open')
      end

      # The conversation that reports writes the activity message later, in Conversations::ActivityMessageJob. Saving that
      # message must not make it the conversation in front either (Message#set_conversation_activity).
      def write_activity_messages(&)
        expect { perform_enqueued_jobs(only: Conversations::ActivityMessageJob, &) }.not_to(change { updated_ats })
      end

      it 'stays open after a conversation that is not in front writes the activity message of an added label' do
        write_activity_messages { described_class.add(contact: contact, labels: %w[vip], conversation: second_conversation) }

        expect(label_activity_messages(second_conversation, 'vip').count).to eq(1)
        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end

      it 'stays open after a conversation that is not in front writes the activity message of a removed label' do
        described_class.add(contact: contact, labels: %w[vip], silent: true)
        give_person_different_statuses(first_conversation, [second_conversation, older_statuses.first],
                                       [third_conversation, older_statuses.last])

        write_activity_messages { described_class.remove(contact: contact, labels: %w[vip], conversation: third_conversation) }

        expect(label_activity_messages(third_conversation, 'vip').count).to eq(1)
        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end
    end
  end

  # One conversation reports a change of the person (conversation events for rules and webhooks, the activity message).
  # Without a conversation the caller acted on, it is the one in front of the person: the one whose status the thread shows.
  describe 'the conversation that reports a change without a source' do
    include PersonThreadStatusHelpers

    def put(conversation, status, at)
      # rubocop:disable Rails/SkipsModelValidations
      conversation.update_columns(status: Conversation.statuses.fetch(status), updated_at: at, last_activity_at: at)
      # rubocop:enable Rails/SkipsModelValidations
      conversation.reload
    end

    def expect_reporter(conversation)
      updates = record_conversation_updates

      expect { described_class.add(contact: contact, labels: %w[vip]) }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once.with(conversation, anything)
      expect(updates).to eq([conversation])
    end

    it 'is the open conversation in front, not an older resolved one' do
      put(first_conversation, 'resolved', 3.hours.ago)
      put(second_conversation, 'open', 1.minute.ago)
      put(third_conversation, 'snoozed', 1.hour.ago)

      expect_reporter(second_conversation)
    end

    it 'is the conversation that is not resolved even when a resolved one changed later' do
      put(first_conversation, 'pending', 2.days.ago)
      put(second_conversation, 'resolved', 1.minute.ago)
      put(third_conversation, 'resolved', 1.hour.ago)

      expect_reporter(first_conversation)
    end

    it 'is the conversation with the latest activity when every conversation is resolved' do
      put(first_conversation, 'resolved', 1.hour.ago)
      put(second_conversation, 'resolved', 1.minute.ago)
      put(third_conversation, 'resolved', 1.day.ago)

      expect_reporter(second_conversation)
    end

    it 'is the next one in front when the conversation in front already carries the label' do
      put(first_conversation, 'resolved', 3.hours.ago)
      put(second_conversation, 'open', 1.minute.ago)
      put(third_conversation, 'snoozed', 1.hour.ago)
      second_conversation.update_labels(%w[vip])
      put(second_conversation, 'open', 1.minute.ago)

      expect_reporter(third_conversation)
    end
  end

  describe '.unify' do
    it 'gives the contact and every conversation the union without events or activity' do
      contact.update_labels(%w[card_only])
      first_conversation.update_labels(%w[first_only])
      third_conversation.update_labels(%w[third_only])
      dispatched.clear

      expect { described_class.unify(contact: contact) }.not_to have_enqueued_job(Conversations::ActivityMessageJob)

      union = %w[card_only first_only third_only]
      expect(contact.reload.label_list).to match_array(union)
      expect(conversations.map { |conversation| conversation.reload.label_list.to_a }).to all(match_array(union))
      expect(dispatched & [Events::Types::CONVERSATION_UPDATED, Events::Types::CONTACT_UPDATED]).to be_empty
    end

    it 'adds the labels of a card that is going away' do
      described_class.unify(contact: contact, extra_labels: %w[from_the_other_card])

      expect(contact.reload.label_list).to eq(%w[from_the_other_card])
      expect(first_conversation.reload.label_list).to eq(%w[from_the_other_card])
    end
  end

  describe '.person_labels' do
    it 'lists the contact first and then every conversation of the contact, once' do
      contact.update_labels(%w[card])
      first_conversation.update_labels(%w[shared one])
      second_conversation.update_labels(%w[shared two])
      create(:conversation, account: account).update_labels(%w[someone_else])

      expect(described_class.person_labels(contact_id: contact.id)).to eq(%w[card shared one two])
    end

    it 'is empty without a contact' do
      expect(described_class.person_labels(contact_id: nil)).to eq([])
    end
  end

  describe '.delta_from_params' do
    def delta(params, visible_labels: [])
      described_class.delta_from_params(ActionController::Parameters.new(params), visible_labels: visible_labels)
    end

    it 'takes add and remove as they are' do
      expect(delta({ add: ['a', ' b ', ''], remove: %w[c] }, visible_labels: %w[x])).to eq([%w[a b], %w[c]])
    end

    it 'turns a whole list into a change against what the client could see' do
      expect(delta({ labels: %w[a c] }, visible_labels: %w[a b])).to eq([%w[a c], %w[b]])
    end

    it 'never removes what the client could not see' do
      expect(delta({ labels: %w[a] }, visible_labels: %w[a])).to eq([%w[a], []])
    end

    it 'reads an empty request as an empty list' do
      expect(delta({}, visible_labels: %w[a])).to eq([[], %w[a]])
    end
  end
end
