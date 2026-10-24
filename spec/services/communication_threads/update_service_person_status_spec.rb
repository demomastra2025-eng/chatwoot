# frozen_string_literal: true

require 'rails_helper'

# "Open", "snooze" and "pending" on a person (a communication thread) touch only the conversations that are not resolved; a
# person whose channels are all resolved gets ONE conversation back, never all of them; "resolve" resolves every channel.
# The status of the person itself is the most urgent status of its channels, see Conversations::CommunicationThreadResolver.
RSpec.describe CommunicationThreads::UpdateService do
  include ActiveJob::TestHelper

  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:dispatcher) { Rails.configuration.dispatcher }
  # The conversations a status event (the one automation rules, webhooks and reports hang on) was dispatched for.
  let(:status_events) { [] }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }

  before do
    Current.user = actor
    allow(dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
      status_events << data[:conversation].id if event == Events::Types::CONVERSATION_STATUS_CHANGED
      original.call(event, time, data)
    end
  end

  after { Current.reset }

  # A channel of the person in the given status, last active the given number of minutes ago. It is built resolved and moved
  # with update_columns, so that a state the merge of the open dialogs would not allow can be put into place.
  def channel(status, minutes_ago:, inbox: create(:inbox, account: account), snoozed_until: nil)
    conversation = create(:conversation, account: account, contact: contact, inbox: inbox,
                                         contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox), status: :resolved)
    conversation.update_columns( # rubocop:disable Rails/SkipsModelValidations
      status: Conversation.statuses.fetch(status.to_s), last_activity_at: minutes_ago.minutes.ago, snoozed_until: snoozed_until
    )
    conversation
  end

  def thread
    CommunicationThread.find_by!(account: account, contact: contact)
  end

  def settle_thread(conversation)
    Conversations::CommunicationThreadResolver.new(conversation: conversation.reload, enforce_single_open_dialog: false).perform
  end

  def update_person(attributes)
    status_events.clear
    params = ActionController::Parameters.new(attributes).permit!
    described_class.new(
      communication_thread: thread, params: params, actor: actor,
      accessible_links: CommunicationThreadConversation.where(communication_thread_id: thread.id)
    ).perform
  end

  def statuses(*conversations)
    conversations.map { |conversation| conversation.reload.status }
  end

  describe 'reopening a resolved person' do
    it 'opens ONE conversation, the one with the latest activity, and leaves the old channels resolved', :aggregate_failures do
      oldest = channel(:resolved, minutes_ago: 5000)
      latest = channel(:resolved, minutes_ago: 30)
      older = channel(:resolved, minutes_ago: 900)
      settle_thread(latest)
      expect(thread.status).to eq('resolved')

      result = update_person(status: 'open')

      expect(statuses(oldest, latest, older)).to eq(%w[resolved open resolved])
      expect(result.status).to eq('open')
      expect(thread.reload.status).to eq('open')
      expect(ConversationStatusTransition.where(conversation_id: [oldest.id, latest.id, older.id]).pluck(:conversation_id, :to_status))
        .to eq([[latest.id, 'open']])
      expect(status_events).to eq([latest.id])
    end

    it 'opens the messenger rather than a call that is only slightly newer' do
      whatsapp = channel(:resolved, minutes_ago: 40)
      voice = channel(:resolved, minutes_ago: 30, inbox: voice_inbox)
      settle_thread(whatsapp)

      update_person(status: 'open')

      expect(statuses(whatsapp, voice)).to eq(%w[open resolved])
    end

    it 'moves one channel to pending or snoozed when asked, not all of them', :aggregate_failures do
      first = channel(:resolved, minutes_ago: 60)
      second = channel(:resolved, minutes_ago: 10)
      settle_thread(second)

      update_person(status: 'snoozed', snoozed_until: 2.days.from_now.to_i)

      expect(statuses(first, second)).to eq(%w[resolved snoozed])
      expect(second.snoozed_until).to be_within(1.minute).of(2.days.from_now)
      expect(thread.reload.status).to eq('snoozed')
    end
  end

  describe 'open, pending and snooze on a person that is not resolved' do
    it 'snoozes only the channels that are not resolved', :aggregate_failures do
      active = channel(:open, minutes_ago: 5)
      sleeping = channel(:snoozed, minutes_ago: 50, snoozed_until: 1.day.from_now)
      old_one = channel(:resolved, minutes_ago: 3000)
      older_one = channel(:resolved, minutes_ago: 6000)
      settle_thread(active)
      until_time = 3.days.from_now

      update_person(status: 'snoozed', snoozed_until: until_time.to_i)

      expect(statuses(active, sleeping, old_one, older_one)).to eq(%w[snoozed snoozed resolved resolved])
      expect(active.snoozed_until).to be_within(1.minute).of(until_time)
      expect(sleeping.snoozed_until).to be_within(1.minute).of(until_time)
      expect(ConversationStatusTransition.where(conversation_id: [old_one.id, older_one.id])).to be_empty
      expect(thread.reload.status).to eq('snoozed')
    end

    it 'marks only the channel that is not resolved as pending', :aggregate_failures do
      active = channel(:open, minutes_ago: 5)
      old_one = channel(:resolved, minutes_ago: 3000)
      settle_thread(active)

      update_person(status: 'pending')

      expect(statuses(active, old_one)).to eq(%w[pending resolved])
      expect(thread.reload.status).to eq('pending')
      expect(status_events).to eq([active.id])
    end

    it 'wakes a snoozed person through the snoozed channel only', :aggregate_failures do
      sleeping = channel(:snoozed, minutes_ago: 20, snoozed_until: 1.day.from_now)
      old_one = channel(:resolved, minutes_ago: 3000)
      settle_thread(sleeping)
      expect(thread.status).to eq('snoozed')

      update_person(status: 'open')

      expect(statuses(sleeping, old_one)).to eq(%w[open resolved])
      expect(thread.reload.status).to eq('open')
      expect(status_events).to eq([sleeping.id])
    end

    it 'resolves every channel that is not resolved', :aggregate_failures do
      active = channel(:open, minutes_ago: 5)
      sleeping = channel(:snoozed, minutes_ago: 50, snoozed_until: 1.day.from_now)
      old_one = channel(:resolved, minutes_ago: 3000)
      settle_thread(active)

      update_person(status: 'resolved')

      expect(statuses(active, sleeping, old_one)).to eq(%w[resolved resolved resolved])
      expect(thread.reload.status).to eq('resolved')
      expect(ConversationStatusTransition.where(conversation_id: old_one.id)).to be_empty
    end

    it 'still writes the other fields of the person to the resolved channels', :aggregate_failures do
      active = channel(:open, minutes_ago: 5)
      old_one = channel(:resolved, minutes_ago: 3000)
      settle_thread(active)

      update_person(status: 'pending', priority: 'urgent')

      expect(statuses(active, old_one)).to eq(%w[pending resolved])
      expect([active, old_one].map { |conversation| conversation.reload.priority }).to eq(%w[urgent urgent])
    end

    it 'puts the one activity note of the status change into the channel that changed', :aggregate_failures do
      old_one = channel(:resolved, minutes_ago: 3000)
      active = channel(:open, minutes_ago: 5)
      settle_thread(active)

      perform_enqueued_jobs { update_person(status: 'pending') }

      note = I18n.t('conversations.activity.status.pending', user_name: actor.name)
      expect(active.messages.activity.pluck(:content)).to include(note)
      expect(old_one.messages.activity.pluck(:content)).not_to include(note)
    end
  end

  describe 'open on a person with several snoozed channels' do
    it 'leaves one open dialog, resolves the other one silently and keeps the callback flag', :aggregate_failures do
      kept = channel(:snoozed, minutes_ago: 10, snoozed_until: 1.day.from_now)
      merged = channel(:snoozed, minutes_ago: 90, snoozed_until: 1.day.from_now)
      merged.update_columns(custom_attributes: { 'waiting_for_callback' => true }) # rubocop:disable Rails/SkipsModelValidations
      settle_thread(kept)

      update_person(status: 'open')

      expect(statuses(kept, merged)).to eq(%w[open resolved])
      expect(Telephony::MissedCallCallbackTracker.waiting_for_callback?(kept.reload)).to be(true)
      expect(thread.reload.status).to eq('open')
      expect(ConversationStatusTransition.where(conversation_id: merged.id).pluck(:to_status, :source)).to include(%w[resolved system])
      # Each channel reports its own wake-up once; the silent resolve of the merged one adds no second event.
      expect(status_events).to contain_exactly(kept.id, merged.id)
    end
  end

  describe 'snooze expiry' do
    it 'wakes only the channels that were snoozed, never an old resolved one', :aggregate_failures do
      active = channel(:open, minutes_ago: 5)
      old_one = channel(:resolved, minutes_ago: 3000)
      older_one = channel(:resolved, minutes_ago: 6000)
      settle_thread(active)
      update_person(status: 'snoozed', snoozed_until: 1.hour.from_now.to_i)
      expect(statuses(active, old_one, older_one)).to eq(%w[snoozed resolved resolved])

      travel_to(2.hours.from_now) { Conversations::ReopenSnoozedConversationsJob.perform_now }

      expect(statuses(active, old_one, older_one)).to eq(%w[open resolved resolved])
      expect(thread.reload.status).to eq('open')
      expect(ConversationStatusTransition.where(conversation_id: [old_one.id, older_one.id])).to be_empty
    end
  end
end
