require 'rails_helper'

# End-to-end system safety nets for Captain-owned (pending) conversations.
# Captain answers only pending conversations, and people are not alerted about
# pending ones: no notification, no assignment and no Open list. So whenever
# Captain cannot or did not produce a valid reply, the conversation must open for
# people through the standard paths. Ported from the PROD-impact probes; the
# scenario ids (a1, b1, ...) match the probe report.
RSpec.describe 'Captain pending conversation safety nets' do # rubocop:disable RSpec/DescribeClass
  include ActiveJob::TestHelper

  let(:account) { create(:account, locale: 'ru', custom_attributes: { plan_name: 'startups' }) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true, enable_email_collect: false) }
  let(:contact) { create(:contact, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let!(:captain_inbox) { create(:captain_inbox, captain_assistant: assistant, inbox: inbox) }
  let(:transfer_text) { 'Transferring to another agent for further assistance.' }

  before do
    create(:inbox_member, user: agent, inbox: inbox)
    OnlineStatusTracker.update_presence(account.id, 'User', agent.id)
    OnlineStatusTracker.set_status(account.id, agent.id, 'online')
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    allow(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later)
  end

  def with_events(&)
    perform_enqueued_jobs(only: [EventDispatcherJob], &)
  end

  def pending_conversation!
    conversation = nil
    with_events { conversation = create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending) }
    conversation
  end

  def new_conversation!
    conversation = nil
    with_events { conversation = create(:conversation, inbox: inbox, account: account, contact: contact) }
    conversation
  end

  def incoming!(conversation, content = 'Customer question')
    message = nil
    with_events do
      message = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: content)
    end
    message
  end

  def working_hours!(open:)
    inbox.update!(working_hours_enabled: true, out_of_office_message: 'Clinic is closed now')
    inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday)
         .update!(open_all_day: open, closed_all_day: !open)
  end

  def exhaust_quota!
    account.update!(
      limits: { 'captain_responses' => 100 },
      custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 100)
    )
  end

  def public_texts(conversation)
    conversation.messages.outgoing.where(private: false).pluck(:content)
  end

  def expect_visible_to_people(conversation)
    conversation.reload
    expect(conversation.status).to eq('open')
    expect(conversation.assignee).to eq(agent)
    expect(Notification.where(account_id: account.id, user_id: agent.id)).to exist
    expect(public_texts(conversation)).not_to include(transfer_text)
  end

  describe 'Captain may not answer now' do
    it 'a1: opens a pending conversation outside working hours in working_hours mode, with the out-of-office template' do
      captain_inbox.update!(auto_reply_mode: 'working_hours')
      working_hours!(open: false)
      conversation = pending_conversation!

      incoming!(conversation)

      expect_visible_to_people(conversation)
      expect(conversation.messages.template.pluck(:content)).to eq(['Clinic is closed now'])
      expect(Captain::Conversation::ResponseBuilderJob).not_to have_received(:perform_later)
    end

    it 'a2: opens a pending conversation during working hours in outside_working_hours mode' do
      captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
      working_hours!(open: true)
      conversation = pending_conversation!

      incoming!(conversation)

      expect_visible_to_people(conversation)
      expect(public_texts(conversation)).to be_empty
    end

    it 'a3: opens every conversation when outside_working_hours mode has no working hours configured' do
      captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
      inbox.update!(working_hours_enabled: false)
      conversation = pending_conversation!

      incoming!(conversation)
      incoming!(conversation, 'Second question')

      expect_visible_to_people(conversation)
      expect(conversation.status_transitions.where(from_status: 'pending', to_status: 'open').count).to eq(1)
    end

    it 'c1: opens a brand-new conversation at night in working_hours mode' do
      captain_inbox.update!(auto_reply_mode: 'working_hours')
      working_hours!(open: false)
      conversation = new_conversation!
      expect(conversation.reload.status).to eq('pending')

      incoming!(conversation)

      expect_visible_to_people(conversation)
    end

    it 'c4: opens a brand-new daytime conversation in outside_working_hours mode' do
      captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
      working_hours!(open: true)
      conversation = new_conversation!
      expect(conversation.reload.status).to eq('pending')

      incoming!(conversation)

      expect_visible_to_people(conversation)
    end
  end

  describe 'Captain quota is used up' do
    it 'b1: hands a pending conversation to people during working hours' do
      working_hours!(open: true)
      conversation = pending_conversation!
      exhaust_quota!

      incoming!(conversation)

      expect_visible_to_people(conversation)
      expect(conversation.captain_handoff_applied_at).to be_present
      expect(Captain::Conversation::ResponseBuilderJob).not_to have_received(:perform_later)
    end

    it 'b2: hands a pending conversation to people at night with the out-of-office template and the assistant handoff message' do
      assistant.update!(config: assistant.config.merge(
        'handoff_message_enabled' => true, 'handoff_message_mode' => 'static', 'handoff_message' => 'Передаю администратору.'
      ))
      working_hours!(open: false)
      conversation = pending_conversation!
      exhaust_quota!

      incoming!(conversation)

      expect_visible_to_people(conversation)
      expect(conversation.messages.template.pluck(:content)).to eq(['Clinic is closed now'])
      expect(public_texts(conversation)).to eq(['Передаю администратору.'])
    end
  end

  describe 'accepted Captain rules that stay in place' do
    it 'd1: never replies in an open conversation, even with the old open-reply setting' do
      captain_inbox.update!(reply_to_open_conversations: true)
      conversation = pending_conversation!
      conversation.update!(status: :open)

      incoming!(conversation)

      expect(Captain::Conversation::ResponseBuilderJob).not_to have_received(:perform_later)
      expect(conversation.reload.status).to eq('open')
      expect(conversation.messages.outgoing).to be_empty
    end

    it 'keeps a pending conversation with Captain while Captain may answer' do
      working_hours!(open: true)
      conversation = pending_conversation!

      incoming!(conversation)

      expect(Captain::Conversation::ResponseBuilderJob).to have_received(:perform_later).once
      expect(conversation.reload.status).to eq('pending')
      expect(conversation.assignee).to be_nil
    end
  end
end
