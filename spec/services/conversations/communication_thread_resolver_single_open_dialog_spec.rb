# frozen_string_literal: true

require 'rails_helper'

# The thread resolver runs on every new conversation, every status change and every message, so the "one open dialog per
# person" rule holds without a separate trigger. The rule itself is covered by CommunicationThreads::SingleOpenDialogService.
RSpec.describe Conversations::CommunicationThreadResolver do
  include ActiveJob::TestHelper

  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
  let(:old_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:current_inbox) { create(:channel_whatsapp_web, account: account).inbox }

  def dialog(inbox, status: :open, minutes_ago: nil)
    create(:conversation, account: account, contact: contact, inbox: inbox, status: status).tap do |conversation|
      conversation.update_columns(last_activity_at: minutes_ago.minutes.ago) if minutes_ago # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def open_conversation_ids
    Conversation.where(account_id: account.id, contact_id: contact.id, status: %w[open pending]).pluck(:id)
  end

  after { Current.reset }

  describe 'one open dialog per person' do
    it 'resolves the dialog of the old inbox when the same person starts a conversation in the current inbox', :aggregate_failures do
      old_dialog = dialog(old_inbox, minutes_ago: 3000)
      expect(open_conversation_ids).to eq([old_dialog.id])

      current_dialog = dialog(current_inbox)

      expect(open_conversation_ids).to eq([current_dialog.id])
      expect(old_dialog.reload).to be_resolved
      expect(current_dialog.communication_thread).to eq(old_dialog.communication_thread)
    end

    it 'keeps the call and the chat of a person in one thread with one open dialog', :aggregate_failures do
      whatsapp = dialog(current_inbox, minutes_ago: 20)
      voice = dialog(voice_inbox)

      expect(open_conversation_ids).to eq([whatsapp.id])
      expect(voice.reload).to be_resolved
      expect(whatsapp.communication_thread.conversations).to contain_exactly(whatsapp, voice)
      expect(whatsapp.communication_thread.status).to eq('open')
    end

    it 'resolves the other open dialog when an incoming message reopens a resolved one', :aggregate_failures do
      resolved_chat = dialog(current_inbox, status: :resolved, minutes_ago: 600)
      voice = dialog(voice_inbox, minutes_ago: 120)
      expect(open_conversation_ids).to eq([voice.id])

      create(:message, conversation: resolved_chat, account: account, inbox: current_inbox, message_type: :incoming,
                       sender: contact, content: 'Hello again')

      expect(open_conversation_ids).to eq([resolved_chat.id])
      expect(voice.reload).to be_resolved
    end

    it 'resolves the other open dialog on new activity of a conversation, whatever its status was before', :aggregate_failures do
      chat = dialog(current_inbox, minutes_ago: 100)
      voice = dialog(voice_inbox, minutes_ago: 400)
      voice.update_columns(status: Conversation.statuses.fetch('open')) # rubocop:disable Rails/SkipsModelValidations
      chat.update_columns(status: Conversation.statuses.fetch('open')) # rubocop:disable Rails/SkipsModelValidations
      expect(open_conversation_ids).to contain_exactly(chat.id, voice.id)

      create(:message, conversation: chat, account: account, inbox: current_inbox, message_type: :outgoing, content: 'Writing back')

      expect(open_conversation_ids).to eq([chat.id])
    end

    it 'keeps the dialog that a person reopened by hand', :aggregate_failures do
      agent = create(:user, account: account, role: :administrator)
      reopened = dialog(old_inbox, status: :resolved, minutes_ago: 3000)
      current = dialog(current_inbox, minutes_ago: 1)
      expect(open_conversation_ids).to eq([current.id])

      Current.user = agent
      Conversations::StatusTransitionService.new(conversation: reopened, params: { status: 'open' }, actor: agent, source: 'manual').perform

      expect(open_conversation_ids).to eq([reopened.id])
      expect(current.reload).to be_resolved
    end

    it 'does not let a timer or a bot reopening decide: the dialog with the latest activity stays', :aggregate_failures do
      old_dialog = dialog(old_inbox, status: :resolved, minutes_ago: 3000)
      current = dialog(current_inbox, minutes_ago: 1)

      Conversations::StatusTransitionService.new(conversation: old_dialog, params: { status: 'open' }, actor: nil, source: 'system').perform

      expect(open_conversation_ids).to eq([current.id])
      expect(old_dialog.reload).to be_resolved
    end

    it 'leaves one open dialog when a whole thread is reopened from the dashboard', :aggregate_failures do
      actor = create(:user, account: account, role: :administrator)
      voice = dialog(voice_inbox, status: :resolved, minutes_ago: 300)
      chat = dialog(current_inbox, status: :resolved, minutes_ago: 200)
      thread = chat.reload.communication_thread
      Current.user = actor

      CommunicationThreads::UpdateService.new(
        communication_thread: thread,
        params: ActionController::Parameters.new(status: 'open').permit!,
        accessible_links: CommunicationThreadConversation.where(communication_thread_id: thread.id),
        actor: actor
      ).perform

      expect(open_conversation_ids).to eq([chat.id])
      expect(voice.reload).to be_resolved
      expect(thread.reload.status).to eq('open')
    end

    it 'leaves the conversations of an account without communication threads alone' do
      account.disable_features!('communication_threads')
      first = dialog(old_inbox)
      second = dialog(current_inbox)

      expect(first.reload).to be_open
      expect(second.reload).to be_open
    end

    it 'does not resolve anything while the backfill repairs the thread links', :aggregate_failures do
      first = dialog(old_inbox, minutes_ago: 100)
      second = dialog(current_inbox, minutes_ago: 1)
      first.update_columns(status: Conversation.statuses.fetch('open')) # rubocop:disable Rails/SkipsModelValidations
      second.update_columns(status: Conversation.statuses.fetch('open')) # rubocop:disable Rails/SkipsModelValidations

      CommunicationThreads::BackfillJob.perform_now(account_id: account.id, dry_run: false)

      expect(open_conversation_ids).to contain_exactly(first.id, second.id)
    end

    it 'never breaks the refresh that triggered it' do
      chat = dialog(current_inbox, minutes_ago: 100)
      allow_any_instance_of(CommunicationThreads::SingleOpenDialogService).to receive(:perform).and_raise(ActiveRecord::StatementInvalid, 'boom') # rubocop:disable RSpec/AnyInstance
      allow(Rails.logger).to receive(:warn)

      thread = described_class.new(conversation: dialog(voice_inbox)).perform

      expect(thread).to eq(chat.reload.communication_thread)
      expect(Rails.logger).to have_received(:warn).with(/single open dialog skipped/).at_least(:once)
    end
  end
end
