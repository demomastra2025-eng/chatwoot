# frozen_string_literal: true

require 'rails_helper'

# An incoming message wakes the whole person: the conversation that receives it opens, the status of the person (the most urgent
# status of its channels) follows, and a snoozed channel of the same person is resolved silently instead of keeping its timer.
# That timer would otherwise open it again later, with its own status events (automation rules, webhooks, reports), for a
# person who is already being handled, or leave the person snoozed once the open dialog is closed.
RSpec.describe Conversations::CommunicationThreadResolver do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:contact) { create(:contact, account: account) }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:dispatcher) { Rails.configuration.dispatcher }
  # The conversations a status event (the one automation rules and webhooks hang on) was dispatched for, in order.
  let(:status_events) { [] }
  # Every event dispatched for a conversation, as [event name, conversation id].
  let(:conversation_events) { [] }

  before do
    Current.account = account
    allow(dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
      status_events << data[:conversation].id if event == Events::Types::CONVERSATION_STATUS_CHANGED
      conversation_events << [event, data[:conversation].id] if data.is_a?(Hash) && data[:conversation].is_a?(Conversation)
      original.call(event, time, data)
    end
  end

  after { Current.reset }

  def channel(status, minutes_ago:, snoozed_until: nil)
    inbox = create(:inbox, account: account)
    create(:conversation, account: account, contact: contact, inbox: inbox,
                          contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox), status: :resolved).tap do |conversation|
      conversation.update_columns( # rubocop:disable Rails/SkipsModelValidations
        status: Conversation.statuses.fetch(status.to_s), last_activity_at: minutes_ago.minutes.ago, snoozed_until: snoozed_until
      )
    end
  end

  def settle_thread(conversation)
    described_class.new(conversation: conversation.reload, enforce_single_open_dialog: false).perform
  end

  def thread
    CommunicationThread.find_by!(account: account, contact: contact)
  end

  def statuses(*conversations)
    conversations.map { |conversation| conversation.reload.status }
  end

  def write(conversation)
    create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :incoming,
                     sender: contact, content: 'Hello again')
  end

  def tab_for(status)
    CommunicationThreadFinder.new(agent, { status: status, assignee_type: 'all' }).perform[:communication_threads].map(&:id)
  end

  def events_for(conversation)
    conversation_events.select { |_event, id| id == conversation.id }.map(&:first)
  end

  it 'opens the person through the channel that received the message and resolves the snoozed channel silently', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 120, snoozed_until: 1.day.from_now)
    resolved = channel(:resolved, minutes_ago: 3000)
    settle_thread(sleeping)
    expect(thread.status).to eq('snoozed')
    expect(tab_for('snoozed')).to eq([thread.id])

    write(resolved)

    expect(statuses(sleeping, resolved)).to eq(%w[resolved open])
    expect(sleeping.snoozed_until).to be_nil
    expect(sleeping.status_transitions.pluck(:from_status, :to_status, :source)).to eq([%w[snoozed resolved system]])
    expect(thread.reload.status).to eq('open')
    expect(tab_for('open')).to eq([thread.id])
    expect(tab_for('snoozed')).to be_empty
    expect(status_events).to eq([resolved.id])
    expect(events_for(sleeping)).to be_empty
  end

  it 'wakes a snoozed channel by its own message and leaves the old resolved channel alone', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 120, snoozed_until: 1.day.from_now)
    old_one = channel(:resolved, minutes_ago: 3000)
    settle_thread(sleeping)

    write(sleeping)

    expect(statuses(sleeping, old_one)).to eq(%w[open resolved])
    expect(thread.reload.status).to eq('open')
    expect(status_events).to eq([sleeping.id])
  end

  it 'keeps one open dialog when the person writes in a resolved channel while another is open', :aggregate_failures do
    open_one = channel(:open, minutes_ago: 60)
    resolved = channel(:resolved, minutes_ago: 3000)
    settle_thread(open_one)

    write(resolved)

    expect(statuses(open_one, resolved)).to eq(%w[resolved open])
    expect(thread.reload.status).to eq('open')
    expect(status_events).to eq([resolved.id])
  end

  # The snooze was dated: on Friday nothing wakes, because the snoozed channel was settled by the message on Wednesday.
  it 'leaves nothing for the snooze timer: no channel opens again when its time is up', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 600, snoozed_until: 2.days.from_now)
    resolved = channel(:resolved, minutes_ago: 3000)
    settle_thread(sleeping)
    write(resolved)
    status_events.clear
    conversation_events.clear

    travel_to(3.days.from_now) { Conversations::ReopenSnoozedConversationsJob.perform_now }

    expect(statuses(sleeping, resolved)).to eq(%w[resolved open])
    expect(thread.reload.status).to eq('open')
    expect(conversation_events).to be_empty
  end

  # The snooze was "until the next reply" (no time): once the dialog the person wrote in is closed by a single-conversation path
  # (auto-resolve, an automation rule, the API), the person is resolved, not left in the snoozed tab.
  it 'does not leave the person snoozed when the dialog they wrote in is closed by itself', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 600)
    resolved = channel(:resolved, minutes_ago: 3000)
    settle_thread(sleeping)
    write(resolved)

    resolved.reload.toggle_status

    expect(statuses(sleeping, resolved)).to eq(%w[resolved resolved])
    expect(thread.reload.status).to eq('resolved')
    expect(tab_for('snoozed')).to be_empty
    expect(tab_for('resolved')).to eq([thread.id])
  end

  # The state the old code left behind: an open dialog next to a snoozed channel. When the timer of the snoozed channel is up it
  # is resolved silently into the open dialog: the first pass already dispatches no event for it, and a second pass of the job
  # and of the thread refresh changes nothing.
  it 'resolves a snoozed channel silently into the open dialog when its time is up', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 600, snoozed_until: 1.minute.ago)
    open_one = channel(:open, minutes_ago: 30)
    settle_thread(open_one)
    expect(thread.status).to eq('open')

    Conversations::ReopenSnoozedConversationsJob.perform_now

    expect(statuses(sleeping, open_one)).to eq(%w[resolved open])
    expect(sleeping.status_transitions.pluck(:from_status, :to_status, :source)).to eq([%w[snoozed resolved system]])
    expect(thread.reload.status).to eq('open')
    expect(conversation_events).to be_empty

    Conversations::ReopenSnoozedConversationsJob.perform_now
    settle_thread(open_one)
    expect(statuses(sleeping, open_one)).to eq(%w[resolved open])
    expect(conversation_events).to be_empty
  end

  it 'waits while a call is live in the open dialog, and settles the snoozed channel once it ended', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 600, snoozed_until: 1.minute.ago)
    call = channel(:open, minutes_ago: 1)
    call.update_columns(additional_attributes: { 'call_status' => 'in_progress' }) # rubocop:disable Rails/SkipsModelValidations
    settle_thread(call)

    Conversations::ReopenSnoozedConversationsJob.perform_now
    expect(statuses(sleeping, call)).to eq(%w[snoozed open])

    call.update_columns(additional_attributes: { 'call_status' => 'completed' }) # rubocop:disable Rails/SkipsModelValidations
    Conversations::ReopenSnoozedConversationsJob.perform_now
    expect(statuses(sleeping, call)).to eq(%w[resolved open])
    expect(status_events).to be_empty
  end
end
