require 'rails_helper'
require 'timeout'

RSpec.describe Captain::InboxPendingConversationsResolutionJob, type: :job do # rubocop:disable RSpec/SpecFilePathFormat
  self.use_transactional_tests = false

  %w[legacy evaluated].each do |mode|
    it "sends one resolution and note when two #{mode} jobs selected the same pending conversation" do # rubocop:disable RSpec/ExampleLength
      account = create(:account)
      account.enable_features!('captain_tasks', 'communication_threads')
      account.update!(auto_resolve_after: 60, captain_auto_resolve_mode: mode)
      inbox = create(:inbox, account: account)
      assistant = create(:captain_assistant, account: account)
      assistant.update!(config: assistant.config.merge(
        'auto_completion_enabled' => true,
        'outcome_reason_settings' => { 'completion_reasons' => [{ 'id' => 'other', 'label' => 'Other' }] },
        'resolution_message_enabled' => true, 'resolution_message_mode' => 'static', 'resolution_message' => 'Resolved'
      ))
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
      conversation = create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago)
      expect(described_class.new.send(:resolvable_pending_conversations, inbox).pluck(:id)).to include(conversation.id)
      fresh_inbox = Inbox.find(inbox.id)
      expect(fresh_inbox.captain_assistant&.auto_completion_enabled?).to be(true)
      expect(described_class.new.send(:resolvable_pending_conversations, fresh_inbox).pluck(:id)).to include(conversation.id)

      if mode == 'evaluated'
        evaluation = instance_double(Captain::ConversationCompletionService,
                                     perform: { evaluated: true, complete: true, reason: 'Complete' })
        allow(Captain::ConversationCompletionService).to receive(:new).and_return(evaluation)
      end

      first_locked = Queue.new
      release_first = Queue.new
      second_started = Queue.new
      allow(Conversations::StatusTransitionService).to receive(:with_locked_conversations_for).and_wrap_original do |method, target, &block|
        second_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i if Thread.current[:resolution_worker] == :second
        method.call(target) do
          if Thread.current[:resolution_worker] == :first
            first_locked << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
            release_first.pop
          end
          block.call
        end
      end

      run_job = lambda do |tag|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Thread.current[:resolution_worker] = tag
            described_class.new.perform(Inbox.find(inbox.id))
          end
        rescue StandardError => e
          e
        ensure
          Thread.current[:resolution_worker] = nil
        end
      end
      first = run_job.call(:first)
      raise first.value if first.join(0.2) && first.value.is_a?(StandardError)

      first_pid = Timeout.timeout(20) { first_locked.pop }
      second = run_job.call(:second)
      second_pid = Timeout.timeout(20) { second_started.pop }
      Timeout.timeout(20) do
        loop do
          blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{second_pid})")
          break if blockers.include?(first_pid.to_s)

          sleep 0.01
        end
      end
      release_first << true
      [first, second].each do |worker|
        result = Timeout.timeout(20) { worker.value }
        raise result if result.is_a?(StandardError)
      end

      public_messages = conversation.messages.outgoing.where(private: false, sender: assistant)
      notes = conversation.messages.outgoing.where(private: true, sender: assistant)
      provider = instance_double(Messages::SendEmailNotificationService, perform: nil)
      allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)
      public_messages.each { |message| SendReplyJob.perform_now(message.id) }

      expect(conversation.reload).to be_resolved
      expect(public_messages.count).to eq(1)
      expect(notes.count).to eq(1)
      expect(provider).to have_received(:perform).once
    ensure
      release_first << true if first&.alive?
      [first, second].compact.each { |worker| worker.kill if worker.alive? }
      [first, second].compact.each(&:join)
      if account&.persisted?
        AutomationEvent.where(account_id: account.id).delete_all
        ConversationStatusTransition.where(account_id: account.id).delete_all
        CommunicationThreadConversation.where(account_id: account.id).delete_all
        CommunicationThread.where(account_id: account.id).destroy_all
        account.destroy!
      end
    end
  end

  %w[completion handoff].each do |outcome|
    it "does not #{outcome} across an incoming commit before its after_commit activity projection" do # rubocop:disable RSpec/ExampleLength
      account = create(:account)
      account.enable_features!('captain_tasks', 'communication_threads')
      account.update!(auto_resolve_after: 60, captain_auto_resolve_mode: 'evaluated')
      inbox = create(:inbox, account: account)
      assistant = create(:captain_assistant, account: account)
      assistant.update!(config: assistant.config.merge(
        'auto_completion_enabled' => true,
        'outcome_reason_settings' => {
          'completion_reasons' => [{ 'id' => 'other', 'label' => 'Other' }],
          'handoff_reasons' => [{ 'id' => 'other', 'label' => 'Other' }]
        },
        'resolution_message_enabled' => true, 'resolution_message_mode' => 'static', 'resolution_message' => 'Resolved',
        'handoff_enabled' => true, 'handoff_message_enabled' => true,
        'handoff_message_mode' => 'static', 'handoff_message' => 'Handing off'
      ))
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
      conversation = create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago)
      evaluation = instance_double(Captain::ConversationCompletionService,
                                   perform: { evaluated: true, complete: outcome == 'completion', reason: 'Customer inactive' })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(evaluation)
      provider = instance_double(Messages::SendEmailNotificationService, perform: nil)
      allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)

      committed = Queue.new
      project = Queue.new
      allow_any_instance_of(Message).to receive(:execute_after_create_commit_callbacks).and_wrap_original do |callback| # rubocop:disable RSpec/AnyInstance
        if Thread.current[:paused_customer_commit] && callback.receiver.incoming?
          committed << [callback.receiver.id, ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i]
          project.pop
        end
        callback.call
      end
      customer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:paused_customer_commit] = true
          create(:message, account: account, inbox: inbox, conversation: Conversation.find(conversation.id),
                           sender: conversation.contact, message_type: :incoming,
                           created_at: (3.hours.ago if outcome == 'handoff'))
        end
      rescue StandardError => e
        e
      ensure
        Thread.current[:paused_customer_commit] = nil
      end
      message_id, customer_pid = Timeout.timeout(20) { committed.pop }
      expect(customer_pid).not_to eq(ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i)
      expect(Message.exists?(message_id)).to be(true) # A second PG connection sees the committed row.
      expect(Message.find(message_id).additional_attributes['captain_contact_activity_pending']).to be(true)
      expect(conversation.reload.last_activity_at).to be < 1.hour.ago

      described_class.new.perform(Inbox.find(inbox.id))
      public_messages = conversation.messages.outgoing.where(private: false, sender: assistant)
      public_messages.each { |message| SendReplyJob.perform_now(message.id) }
      expect(provider).not_to have_received(:perform)
      expect(public_messages).to be_empty
      expect(conversation.messages.outgoing.where(private: true, sender: assistant)).to be_empty
      expect(conversation.reload).to be_pending
      project << true
      result = Timeout.timeout(20) { customer.value }
      raise result if result.is_a?(StandardError)

      expect(result.additional_attributes).not_to have_key('captain_contact_activity_pending')
      expect(Message.find(message_id).additional_attributes).not_to have_key('captain_contact_activity_pending')
      expect(conversation.reload.last_activity_at).to be > 1.minute.ago
      described_class.new.perform(Inbox.find(inbox.id))
      expect(conversation.reload).to be_pending
      expect(conversation.messages.outgoing.where(sender: assistant)).to be_empty
    ensure
      project << true if customer&.alive?
      result = Timeout.timeout(20) { customer.value } if customer
      raise result if result.is_a?(StandardError)

      if account&.persisted?
        AutomationEvent.where(account_id: account.id).delete_all
        ConversationStatusTransition.where(account_id: account.id).delete_all
        CommunicationThreadConversation.where(account_id: account.id).delete_all
        CommunicationThread.where(account_id: account.id).destroy_all
        account.destroy!
      end
    end
  end
end
