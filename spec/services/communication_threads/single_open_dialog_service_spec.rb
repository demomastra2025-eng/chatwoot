# frozen_string_literal: true

require 'rails_helper'

# "One person, one open dialog": the conversations of a communication thread that are open or pending together are
# resolved silently except for one.
RSpec.describe CommunicationThreads::SingleOpenDialogService do
  include ActiveJob::TestHelper

  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
  let(:whatsapp_inbox) { create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false).inbox }
  let(:thread) { CommunicationThread.find_by!(account: account, contact: contact) }

  # A conversation that is open since some minutes, created without the live rule so that a thread can be put into the state the
  # production data is in.
  def open_dialog(inbox, minutes_ago:, status: :open, contact: self.contact, labels: nil)
    create(:conversation, account: inbox.account, contact: contact, inbox: inbox, status: :resolved).tap do |conversation|
      conversation.update_labels(labels) if labels
      conversation.update_columns(status: Conversation.statuses.fetch(status.to_s), last_activity_at: minutes_ago.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def statuses(*conversations)
    conversations.map { |conversation| conversation.reload.status }
  end

  describe 'which conversation stays' do
    it 'keeps the messenger when a call is only slightly newer', :aggregate_failures do
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 10)
      voice = open_dialog(voice_inbox, minutes_ago: 1)

      plan = described_class.new(thread: thread).perform

      expect(plan.kept).to eq(whatsapp)
      expect(plan.closed).to eq([voice])
      expect(statuses(whatsapp, voice)).to eq(%w[open resolved])
      expect(thread.reload.status).to eq('open')
    end

    it 'keeps the call when it is much newer than the messenger' do
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 180)
      voice = open_dialog(voice_inbox, minutes_ago: 1)

      described_class.new(thread: thread).perform

      expect(statuses(whatsapp, voice)).to eq(%w[resolved open])
    end

    it 'keeps the messenger when it has the latest activity' do
      voice = open_dialog(voice_inbox, minutes_ago: 120)
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 2)

      described_class.new(thread: thread).perform

      expect(statuses(whatsapp, voice)).to eq(%w[open resolved])
    end

    it 'keeps the dialog of the current inbox when the same channel is open twice', :aggregate_failures do
      old_inbox = create(:channel_whatsapp_web, account: account).inbox
      current_inbox = create(:channel_whatsapp_web, account: account).inbox
      old_dialog = open_dialog(old_inbox, minutes_ago: 3000)
      current_dialog = open_dialog(current_inbox, minutes_ago: 5)

      plan = described_class.new(thread: thread).perform

      expect(plan.kept).to eq(current_dialog)
      expect(statuses(current_dialog, old_dialog)).to eq(%w[open resolved])
    end

    it 'counts a pending conversation as open and leaves a snoozed one alone', :aggregate_failures do
      snoozed = open_dialog(voice_inbox, minutes_ago: 1, status: :snoozed)
      pending_dialog = open_dialog(whatsapp_inbox, minutes_ago: 30, status: :pending)
      open_one = open_dialog(create(:channel_whatsapp_web, account: account).inbox, minutes_ago: 5)

      plan = described_class.new(thread: thread).perform

      expect(plan.closed).to eq([pending_dialog])
      expect(statuses(open_one, snoozed, pending_dialog)).to eq(%w[open snoozed resolved])
    end

    it 'keeps the conversation a person has just reopened by hand', :aggregate_failures do
      reopened = open_dialog(voice_inbox, minutes_ago: 600)
      current = open_dialog(whatsapp_inbox, minutes_ago: 1)

      plan = described_class.new(thread: thread, preferred_conversation_id: reopened.id).perform

      expect(plan.kept).to eq(reopened)
      expect(statuses(reopened, current)).to eq(%w[open resolved])
    end

    it 'does nothing for a thread with one open conversation' do
      only = open_dialog(whatsapp_inbox, minutes_ago: 5)
      open_dialog(voice_inbox, minutes_ago: 1, status: :resolved)

      expect(described_class.new(thread: thread).perform).to be_nil
      expect(only.reload).to be_open
    end
  end

  describe 'a live call' do
    it 'is never closed, and nothing is decided while it lasts', :aggregate_failures do
      voice = open_dialog(voice_inbox, minutes_ago: 1)
      voice.update_columns(additional_attributes: { 'call_status' => 'in_progress' }) # rubocop:disable Rails/SkipsModelValidations
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 0)

      plan = described_class.new(thread: thread).perform

      expect(plan.deferred).to eq(:live_call)
      expect(plan.closed).to be_empty
      expect(statuses(voice, whatsapp)).to eq(%w[open open])
    end

    it 'is decided once the call has ended, by the refresh of the thread', :aggregate_failures do
      voice = open_dialog(voice_inbox, minutes_ago: 1)
      voice.update_columns(additional_attributes: { 'call_status' => 'in_progress' }) # rubocop:disable Rails/SkipsModelValidations
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 0)
      voice.update!(additional_attributes: { 'call_status' => 'completed' })

      expect(statuses(whatsapp, voice)).to eq(%w[open resolved])
    end

    it 'ignores a call that was never closed out and has not moved for hours' do
      voice = open_dialog(voice_inbox, minutes_ago: 600)
      voice.update_columns(additional_attributes: { 'call_status' => 'ringing' }, updated_at: 10.hours.ago) # rubocop:disable Rails/SkipsModelValidations
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 1)

      described_class.new(thread: thread).perform

      expect(statuses(whatsapp, voice)).to eq(%w[open resolved])
    end
  end

  describe 'the silent close' do
    let!(:whatsapp) { open_dialog(whatsapp_inbox, minutes_ago: 5) }
    let!(:voice) { open_dialog(voice_inbox, minutes_ago: 1) }
    let(:dispatcher) { Rails.configuration.dispatcher }

    before do
      [whatsapp_inbox, voice_inbox].each { |inbox| inbox.update!(csat_survey_enabled: true) }
      thread
      allow(dispatcher).to receive(:dispatch).and_call_original
      clear_enqueued_jobs
    end

    it 'sends nothing to the customer and starts no CSAT survey', :aggregate_failures do
      messages_before = Message.where(account_id: account.id).pluck(:id)
      allow(CsatSurveyService).to receive(:new).and_call_original

      described_class.new(thread: thread).perform
      perform_enqueued_jobs(only: Conversations::ActivityMessageJob)

      new_messages = Message.where(account_id: account.id).where.not(id: messages_before)
      expect(new_messages.pluck(:message_type)).to eq(['activity'])
      expect(new_messages.pluck(:content_type)).not_to include('input_csat')
      expect(CsatSurveyService).not_to have_received(:new)
      expect(SendReplyJob).not_to have_been_enqueued
      expect(voice.reload).to be_resolved
    end

    it 'dispatches no resolved or status event, so no automation rule, webhook or report reacts', :aggregate_failures do
      create(:automation_rule, account: account, event_name: 'conversation_resolved', conditions: [])

      described_class.new(thread: thread).perform

      expect(voice.reload).to be_resolved
      [Events::Types::CONVERSATION_RESOLVED, Events::Types::CONVERSATION_STATUS_CHANGED, Events::Types::CONVERSATION_UPDATED,
       Events::Types::CONVERSATION_OPENED].each do |event_name|
        expect(dispatcher).not_to have_received(:dispatch).with(event_name, anything, anything)
      end
      expect(enqueued_jobs.pluck('job_class')).not_to include('EventDispatcherJob')
    end

    it 'does not run an automation rule of the resolved event (a normal resolve does)', :aggregate_failures do
      create(:automation_rule, account: account, event_name: 'conversation_resolved', conditions: [])
      other = create(:conversation, account: account, contact: create(:contact, account: account), status: :open)
      allow(AutomationRuleListener.instance).to receive(:conversation_resolved)
      clear_enqueued_jobs

      other.update!(status: :resolved)
      perform_enqueued_jobs(only: EventDispatcherJob)
      expect(AutomationRuleListener.instance).to have_received(:conversation_resolved).once

      described_class.new(thread: thread).perform
      perform_enqueued_jobs(only: EventDispatcherJob)
      expect(AutomationRuleListener.instance).to have_received(:conversation_resolved).once
    end

    it 'records the change as a system transition and does not clear the assignee or the labels', :aggregate_failures do
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: voice_inbox, user: agent)
      voice.update_columns(assignee_id: agent.id) # rubocop:disable Rails/SkipsModelValidations
      voice.update_labels(%w[vip first-visit])

      described_class.new(thread: thread).perform

      transition = voice.status_transitions.order(:id).last
      expect(transition).to have_attributes(from_status: 'open', to_status: 'resolved', source: 'system', actor_id: nil)
      expect(transition.metadata['single_open_dialog']).to eq('kept_conversation_id' => whatsapp.id)
      expect(voice.reload.assignee_id).to eq(agent.id)
      expect(voice.label_list).to match_array(%w[vip first-visit])
    end

    it 'tells the dashboards through the realtime listener only', :aggregate_failures do
      listener = ActionCableListener.instance
      allow(listener).to receive(:conversation_status_changed).and_call_original

      described_class.new(thread: thread).perform

      expect(listener).to have_received(:conversation_status_changed).once do |event|
        expect(event.data[:conversation]).to eq(voice)
      end
    end

    it 'writes an activity note into the kept conversation that says what was merged', :aggregate_failures do
      account.update!(locale: 'ru')

      described_class.new(thread: thread).perform
      perform_enqueued_jobs(only: Conversations::ActivityMessageJob)

      note = whatsapp.messages.activity.order(:id).last
      expect(note.content).to eq("Объединено: звонок из канала «#{voice_inbox.name}»")
      expect(note.additional_attributes['single_open_dialog_merged_conversation_id']).to eq(voice.id)
    end

    it 'says dialog instead of call for a messenger' do
      account.update!(locale: 'ru')
      old_inbox = create(:channel_whatsapp_web, account: account).inbox
      old_dialog = open_dialog(old_inbox, minutes_ago: 400)
      voice.update_columns(status: Conversation.statuses.fetch('resolved')) # rubocop:disable Rails/SkipsModelValidations

      described_class.new(thread: thread).perform
      perform_enqueued_jobs(only: Conversations::ActivityMessageJob)

      expect(whatsapp.messages.activity.pluck(:content)).to include("Объединено: диалог из канала «#{old_inbox.name}»")
      expect(old_dialog.reload).to be_resolved
    end
  end

  describe 'the waiting-for-callback state of a missed call' do
    let(:missed_at) { '2026-10-24T10:00:00Z' }
    let!(:whatsapp) { open_dialog(whatsapp_inbox, minutes_ago: 10) }
    let!(:voice) do
      open_dialog(voice_inbox, minutes_ago: 1).tap do |conversation|
        conversation.update_columns( # rubocop:disable Rails/SkipsModelValidations
          custom_attributes: { 'waiting_for_callback' => true },
          additional_attributes: { 'waiting_for_callback' => true, 'last_missed_call_ref' => 'call-77', 'last_missed_call_at' => missed_at }
        )
      end
    end

    it 'moves to the conversation that stays and stays on the resolved call', :aggregate_failures do
      described_class.new(thread: thread).perform

      expect(whatsapp.reload).to be_open
      expect(whatsapp.custom_attributes).to include('waiting_for_callback' => true)
      expect(whatsapp.additional_attributes).to include(
        'waiting_for_callback' => true, 'last_missed_call_ref' => 'call-77', 'last_missed_call_at' => missed_at
      )
      expect(Telephony::MissedCallCallbackTracker.waiting_for_callback?(voice.reload)).to be(true)
    end

    it 'keeps the thread in the waiting-for-callback list', :aggregate_failures do
      admin = create(:user, account: account, role: :administrator)

      described_class.new(thread: thread).perform

      result = CommunicationThreadFinder.new(admin, { waiting_for_callback: 'true' }, account).perform
      expect(result[:communication_threads].map(&:id)).to eq([thread.id])
      conversations = ConversationFinder.new(admin, { waiting_for_callback: 'true' }, account).perform[:conversations]
      expect(conversations.map(&:id)).to eq([whatsapp.id])
    end

    it 'is cleared everywhere by the callback: the next outgoing message', :aggregate_failures do
      described_class.new(thread: thread).perform
      voice_message = create(:message, conversation: voice, account: account, inbox: voice_inbox, message_type: :incoming,
                                       content_type: :voice_call, content: 'Missed call',
                                       content_attributes: { 'data' => { 'waiting_for_callback' => true } })

      create(:message, conversation: whatsapp.reload, account: account, inbox: whatsapp_inbox, message_type: :outgoing, content: 'Calling you back')

      expect(whatsapp.reload.additional_attributes['waiting_for_callback']).to be(false)
      expect(voice.reload.additional_attributes['waiting_for_callback']).to be(false)
      expect(voice_message.reload.content_attributes.dig('data', 'waiting_for_callback')).to be(false)
    end

    it 'is not downgraded when the conversation that stays already waits for a callback' do
      whatsapp.update_columns(additional_attributes: { 'waiting_for_callback' => true, 'last_missed_call_ref' => 'call-90', # rubocop:disable Rails/SkipsModelValidations
                                                       'last_missed_call_at' => '2026-10-24T12:00:00Z' })

      described_class.new(thread: thread).perform

      expect(whatsapp.reload.additional_attributes).to include('last_missed_call_ref' => 'call-90')
    end
  end

  describe 'labels and routing of the person' do
    it 'adds the labels of the resolved conversation to the one that stays, without an activity message', :aggregate_failures do
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 10, labels: %w[vip])
      voice = open_dialog(voice_inbox, minutes_ago: 1, labels: %w[callback])

      described_class.new(thread: thread).perform

      expect(whatsapp.reload.label_list).to match_array(%w[vip callback])
      expect(voice.reload.label_list).to match_array(%w[callback])
      expect(whatsapp.messages.activity.pluck(:content).grep(/label/i)).to be_empty
    end

    it 'gives the conversation that stays the assignee of the thread when it has none', :aggregate_failures do
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: whatsapp_inbox, user: agent)
      whatsapp = open_dialog(whatsapp_inbox, minutes_ago: 10)
      voice = open_dialog(voice_inbox, minutes_ago: 1)
      voice.update_columns(assignee_id: agent.id) # rubocop:disable Rails/SkipsModelValidations
      Conversations::CommunicationThreadResolver.new(conversation: voice, enforce_single_open_dialog: false).perform
      expect(thread.reload.assignee_id).to eq(agent.id)

      described_class.new(thread: thread).perform

      expect(whatsapp.reload.assignee_id).to eq(agent.id)
      expect(thread.reload.assignee_id).to eq(agent.id)
    end
  end

  describe 'dry run' do
    it 'returns the plan and writes nothing', :aggregate_failures do
      open_dialog(whatsapp_inbox, minutes_ago: 10)
      voice = open_dialog(voice_inbox, minutes_ago: 1)
      voice.update_columns(additional_attributes: { 'waiting_for_callback' => true }) # rubocop:disable Rails/SkipsModelValidations
      before = [Conversation.order(:id).pluck(:id, :status, :additional_attributes, :updated_at), Message.count,
                ConversationStatusTransition.count]
      clear_enqueued_jobs

      plan = described_class.new(thread: thread, dry_run: true).perform

      expect(plan.closed).to eq([voice])
      expect([Conversation.order(:id).pluck(:id, :status, :additional_attributes, :updated_at), Message.count,
              ConversationStatusTransition.count]).to eq(before)
      expect(enqueued_jobs).to be_empty
    end
  end

  describe '.threads_to_consolidate' do
    it 'lists the threads with two open or pending conversations of the account', :aggregate_failures do
      open_dialog(whatsapp_inbox, minutes_ago: 10)
      open_dialog(voice_inbox, minutes_ago: 1, status: :pending)
      single_contact = create(:contact, account: account)
      create(:conversation, account: account, contact: single_contact, inbox: whatsapp_inbox, status: :open)
      other_account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      other_contact = create(:contact, account: other_account)
      2.times { open_dialog(create(:inbox, account: other_account), minutes_ago: 5, contact: other_contact) }

      expect(described_class.threads_to_consolidate(account_id: account.id)).to contain_exactly(thread)
      expect(described_class.threads_to_consolidate.map(&:account_id)).to include(account.id, other_account.id)
    end
  end
end
