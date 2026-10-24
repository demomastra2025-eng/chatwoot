# frozen_string_literal: true

require 'rails_helper'

# An incoming message wakes the person: the conversation that receives it opens, and the status of the person (the most urgent
# status of its channels) follows. The other channels are settled by the rule "one open dialog per person" without any
# change flipping back and forth.
RSpec.describe Conversations::CommunicationThreadResolver do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:contact) { create(:contact, account: account) }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:dispatcher) { Rails.configuration.dispatcher }
  # The conversations a status event (the one automation rules and webhooks hang on) was dispatched for, in order.
  let(:status_events) { [] }

  before do
    Current.account = account
    allow(dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
      status_events << data[:conversation].id if event == Events::Types::CONVERSATION_STATUS_CHANGED
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

  it 'opens the person through the channel that received the message and leaves the snoozed channel snoozed', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 120, snoozed_until: 1.day.from_now)
    resolved = channel(:resolved, minutes_ago: 3000)
    settle_thread(sleeping)
    expect(thread.status).to eq('snoozed')
    expect(tab_for('snoozed')).to eq([thread.id])

    write(resolved)

    expect(statuses(sleeping, resolved)).to eq(%w[snoozed open])
    expect(thread.reload.status).to eq('open')
    expect(tab_for('open')).to eq([thread.id])
    expect(tab_for('snoozed')).to be_empty
    expect(status_events).to eq([resolved.id])
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

  it 'settles the snoozed channel without flipping anything back when its time is up', :aggregate_failures do
    sleeping = channel(:snoozed, minutes_ago: 600, snoozed_until: 1.day.from_now)
    resolved = channel(:resolved, minutes_ago: 3000)
    settle_thread(sleeping)
    write(resolved)
    sleeping.update_columns(snoozed_until: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
    status_events.clear

    Conversations::ReopenSnoozedConversationsJob.perform_now
    expect(statuses(sleeping, resolved)).to eq(%w[resolved open])
    expect(thread.reload.status).to eq('open')

    # A second pass of the job and of the thread refresh changes nothing: no channel is opened or closed again.
    settled_events = status_events.dup
    Conversations::ReopenSnoozedConversationsJob.perform_now
    settle_thread(resolved)
    expect(statuses(sleeping, resolved)).to eq(%w[resolved open])
    expect(thread.reload.status).to eq('open')
    expect(status_events).to eq(settled_events)
  end
end
