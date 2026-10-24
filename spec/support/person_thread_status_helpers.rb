# frozen_string_literal: true

# The status of a person's communication thread is the status of the open (not resolved) conversation that changed last
# (Conversations::CommunicationThreadResolver#aggregate_status). A label is not a change of status, so a label written to
# the person must never move it. These helpers build a person whose conversations disagree about their status, and read
# the thread status the way the list and the realtime update show it.
module PersonThreadStatusHelpers
  # The first conversation is open, talked last and decides the thread. The others are older, most recent first, each with
  # the status it keeps (snoozed, pending). A write that saved an older one after the first would put it in front.
  def give_person_different_statuses(open, *older)
    open.account.enable_features!('communication_threads')
    states = [[open, 'open']] + older
    states.each_with_index do |(conversation, status), index|
      at = index.zero? ? 1.minute.ago : index.hours.ago
      # rubocop:disable Rails/SkipsModelValidations
      conversation.update_columns(status: Conversation.statuses.fetch(status), updated_at: at, last_activity_at: at)
      # rubocop:enable Rails/SkipsModelValidations
    end
    states.reverse_each { |conversation, _status| conversation.reload.refresh_communication_thread! }
    expect(thread_status_of(open)).to eq('open')
  end

  # The conversations that fire conversation_updated from now on: what automation rules and webhooks receive.
  def record_conversation_updates
    updates = []
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, *args|
      data = args[2]
      updates << data[:conversation] if args.first == Events::Types::CONVERSATION_UPDATED && data.is_a?(Hash)
      original.call(*args)
    end
    updates
  end

  # The label activity messages written into a conversation (by Conversations::ActivityMessageJob).
  def label_activity_messages(conversation, label)
    conversation.messages.activity.where('content LIKE ?', "%#{label}%")
  end

  def thread_status_of(conversation)
    CommunicationThread.find_by!(account_id: conversation.account_id, contact_id: conversation.contact_id).status
  end

  # The status the dashboards receive for the thread: what CommunicationThreads::RealtimeUpdateService broadcasts to an
  # administrator of the account.
  def realtime_status_of(conversation)
    account = conversation.account
    create(:user, account: account, role: :administrator) if account.administrators.none?
    broadcasts = []
    allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }
    CommunicationThreads::RealtimeUpdateService.new(
      communication_thread_id: conversation.reload.communication_thread.id,
      source_conversation_id: conversation.id,
      source_event: 'conversation.updated'
    ).perform
    broadcasts.find { |_members, event, _payload| event == CommunicationThreads::RealtimeUpdateService::EVENT_NAME }&.last&.dig(:status)
  end
end
