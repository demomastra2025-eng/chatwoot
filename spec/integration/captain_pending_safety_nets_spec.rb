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

  describe 'a Captain turn without a valid reply' do
    def run_captain_turn!(conversation, message, response: nil, error: nil)
      runner = instance_double(Captain::Assistant::AgentRunnerService)
      if error
        allow(runner).to receive(:generate_response).and_raise(error)
      else
        allow(runner).to receive(:generate_response).and_return(response)
      end
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
      with_events { Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, expected_last_message_id: message.id) }
    end

    def model_output(conversation, output)
      runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: conversation)
      runner.send(:process_agent_result, Struct.new(:output, :context, :error).new(output, { current_agent: 'assistant' }, nil))
    end

    let(:failed_turn_note) { Captain::Conversation::ResponseBuilderJob::FAILED_TURN_HANDOFF_NOTE }

    before { working_hours!(open: true) }

    it 'h1: hands the conversation to people when the provider call fails' do
      conversation = pending_conversation!
      message = incoming!(conversation)

      run_captain_turn!(conversation, message, error: StandardError.new('provider down'))

      expect_visible_to_people(conversation)
      expect(conversation.messages.where(private: true).pluck(:content)).to eq([failed_turn_note])
      expect(public_texts(conversation)).to be_empty
    end

    it 'h2: hands the conversation to people when the model returns a blank reply' do
      conversation = pending_conversation!
      message = incoming!(conversation)

      run_captain_turn!(conversation, message, response: { 'response' => '', 'reasoning' => '' })

      expect_visible_to_people(conversation)
      expect(conversation.messages.where(private: true).pluck(:content)).to eq([failed_turn_note])
    end

    it 'h3: hands the conversation to people when the model emits conversation_handoff instead of calling the tool' do
      assistant.update!(config: assistant.config.merge(
        'handoff_message_enabled' => true, 'handoff_message_mode' => 'ai', 'handoff_message' => 'Передаю администратору.'
      ))
      conversation = pending_conversation!
      message = incoming!(conversation, 'Позовите администратора')
      response = model_output(conversation, { 'response' => 'conversation_handoff', 'handoff_message' => 'Model text' })

      run_captain_turn!(conversation, message, response: response)

      expect_visible_to_people(conversation)
      expect(public_texts(conversation)).to eq(['Передаю администратору.'])
    end
  end

  describe 'a Captain turn stopped by moderation' do
    it 'm: hands the conversation to people when the safety policy blocks or cannot check the turn' do
      working_hours!(open: true)
      runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: pending_conversation!)
      [
        'Agent input blocked by moderation policy',
        'Agent output blocked because moderation policy is unavailable'
      ].each do |reason|
        conversation = pending_conversation!
        message = incoming!(conversation)
        blocked = runner.send(:blocked_by_moderation_response, reason)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new)
          .and_return(instance_double(Captain::Assistant::AgentRunnerService, generate_response: blocked))

        with_events { Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, expected_last_message_id: message.id) }

        expect_visible_to_people(conversation)
        expect(conversation.messages.where(private: true).pluck(:content))
          .to eq([Captain::Conversation::ResponseBuilderJob::MODERATION_HANDOFF_NOTE])
        expect(public_texts(conversation)).to be_empty
      end
    end
  end

  describe 'the pending-resolution job' do
    let(:evaluations) { [] }

    before do
      working_hours!(open: true)
      account.enable_features!('captain_tasks')
      account.update!(auto_resolve_after: 60)
      account.update_columns(settings: account.reload.settings.to_h.merge('captain_auto_resolve_mode' => 'evaluated')) # rubocop:disable Rails/SkipsModelValidations
    end

    def stale_pending_conversation!
      conversation = pending_conversation!
      incoming!(conversation)
      conversation.update_columns(last_activity_at: 2.hours.ago) # rubocop:disable Rails/SkipsModelValidations
      conversation
    end

    def run_resolution_job!(times: 1)
      times.times { with_events { Captain::InboxPendingConversationsResolutionJob.perform_now(inbox.reload) } }
    end

    def stub_evaluator(api_result)
      allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_wrap_original do |method, **kwargs|
        method.call(**kwargs).tap do |evaluator|
          allow(evaluator).to receive(:make_api_call) do
            evaluations << kwargs[:conversation_display_id]
            api_result
          end
        end
      end
    end

    it 'e1: hands an unfinished conversation to people once instead of re-evaluating it every run' do
      conversation = stale_pending_conversation!
      stub_evaluator({ message: { 'complete' => false, 'reason' => 'Customer question is still open' } })

      run_resolution_job!(times: 3)

      expect_visible_to_people(conversation)
      expect(evaluations).to eq([conversation.display_id])
      expect(conversation.messages.where(private: true).pluck(:content)).to eq(['Auto-handoff: Customer question is still open'])
    end

    it 'e2: hands the conversation to people when the completion check itself fails' do
      conversation = stale_pending_conversation!
      stub_evaluator({ error: 'Completion model unavailable' })

      run_resolution_job!(times: 2)

      expect_visible_to_people(conversation)
      expect(evaluations).to eq([conversation.display_id])
    end

    it 'still resolves a finished conversation' do
      conversation = stale_pending_conversation!
      stub_evaluator({ message: { 'complete' => true, 'reason' => 'Answered' } })

      run_resolution_job!

      expect(conversation.reload.status).to eq('resolved')
    end
  end

  describe 'the release boundary' do
    it 'v4: answers a message stamped by the previous release instead of dropping the reply' do
      working_hours!(open: true)
      conversation = pending_conversation!
      message = incoming!(conversation)
      legacy_stamp = message.reload.additional_attributes.to_h.slice('captain_control_generation')
      message.update_columns(additional_attributes: legacy_stamp) # rubocop:disable Rails/SkipsModelValidations
      allow(Captain::Assistant::AgentRunnerService).to receive(:new)
        .and_return(instance_double(Captain::Assistant::AgentRunnerService, generate_response: { 'response' => 'Здравствуйте!' }))

      with_events { Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, expected_last_message_id: message.id) }

      expect(conversation.reload.status).to eq('pending')
      expect(public_texts(conversation)).to eq(['Здравствуйте!'])
    end
  end

  # Owner rule (30.09): on every system handoff the only text the customer gets
  # is the assistant's own handoff message, and only while its toggle is on. No
  # built-in wording, and no model or generated text in static mode.
  describe 'the customer-facing text of a system handoff' do
    let(:handoff_text) { 'Передаю администратору.' }

    before do
      working_hours!(open: true)
      account.enable_features!('captain_tasks')
      account.update!(auto_resolve_after: 60)
      account.update_columns(settings: account.reload.settings.to_h.merge('captain_auto_resolve_mode' => 'evaluated')) # rubocop:disable Rails/SkipsModelValidations
    end

    def handoff_message!(enabled:, text: handoff_text)
      assistant.update!(config: assistant.config.merge(
        'handoff_message_enabled' => enabled, 'handoff_message_mode' => 'static', 'handoff_message' => text
      ))
    end

    def customer_texts(conversation)
      conversation.messages.where(private: false, message_type: %w[outgoing template]).pluck(:content)
    end

    def captain_turn!(conversation, error: nil)
      message = incoming!(conversation)
      response = yield if block_given?
      runner = instance_double(Captain::Assistant::AgentRunnerService)
      if error
        allow(runner).to receive(:generate_response).and_raise(error)
      else
        allow(runner).to receive(:generate_response).and_return(response)
      end
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
      with_events { Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, expected_last_message_id: message.id) }
    end

    def runtime_runner(conversation)
      Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: conversation)
    end

    def quota_used_up!(conversation)
      exhaust_quota!
      incoming!(conversation)
    end

    def provider_error!(conversation)
      captain_turn!(conversation, error: StandardError.new('provider down'))
    end

    def handoff_value_without_the_tool!(conversation)
      output = { 'response' => 'conversation_handoff', 'handoff_message' => 'Model text' }
      result = Struct.new(:output, :context, :error).new(output, { current_agent: 'assistant' }, nil)
      captain_turn!(conversation) { runtime_runner(conversation).send(:process_agent_result, result) }
    end

    def moderation_block!(conversation)
      reason = 'Agent input blocked by moderation policy'
      captain_turn!(conversation) { runtime_runner(conversation).send(:blocked_by_moderation_response, reason) }
    end

    def unfinished_conversation!(conversation)
      incoming!(conversation)
      conversation.update_columns(last_activity_at: 2.hours.ago) # rubocop:disable Rails/SkipsModelValidations
      completion = instance_double(Captain::ConversationCompletionService,
                                   perform: { complete: false, reason: 'Open question', message: 'Model text' })
      allow(Captain::ConversationCompletionService).to receive(:new).and_return(completion)
      with_events { Captain::InboxPendingConversationsResolutionJob.perform_now(inbox.reload) }
    end

    def system_handoff!(path)
      conversation = pending_conversation!
      send(:"#{path}!", conversation)
      conversation.reload
    end

    %w[quota_used_up provider_error handoff_value_without_the_tool moderation_block unfinished_conversation].each do |path|
      context "with a system handoff after #{path.tr('_', ' ')}" do
        it 'sends only the configured handoff message, once, while its toggle is on' do
          handoff_message!(enabled: true)

          conversation = system_handoff!(path)

          expect_visible_to_people(conversation)
          expect(customer_texts(conversation)).to eq([handoff_text])
        end

        it 'sends no text while the handoff message toggle is off, even with a configured message' do
          handoff_message!(enabled: false)

          conversation = system_handoff!(path)

          expect_visible_to_people(conversation)
          expect(customer_texts(conversation)).to be_empty
        end

        it 'never falls back to built-in wording when no handoff message is configured' do
          handoff_message!(enabled: true, text: '')

          conversation = system_handoff!(path)

          expect_visible_to_people(conversation)
          expect(customer_texts(conversation)).to be_empty
        end
      end
    end
  end

  describe 'accepted Captain rules that stay in place' do
    def run_captain_turn!(conversation, message, response)
      runner = instance_double(Captain::Assistant::AgentRunnerService, generate_response: response)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
      with_events { Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant, expected_last_message_id: message.id) }
    end

    it 'f2: the AI never hands off without the enabled handoff tool' do
      assistant.update!(config: assistant.config.merge('tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }))
      conversation = pending_conversation!
      message = incoming!(conversation)

      run_captain_turn!(conversation, message, { 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true })

      expect(conversation.reload.status).to eq('pending')
      expect(conversation.captain_handoff_applied_at).to be_nil
      expect(conversation.messages.outgoing).to be_empty
    end

    it 'f4: a reply that only talks about a transfer stays a normal Captain reply' do
      conversation = pending_conversation!
      message = incoming!(conversation)

      run_captain_turn!(conversation, message, { 'response' => 'Сейчас передам вас администратору.' })

      expect(conversation.reload.status).to eq('pending')
      expect(public_texts(conversation)).to eq(['Сейчас передам вас администратору.'])
      expect(conversation.messages.where(private: true)).to be_empty
    end

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
