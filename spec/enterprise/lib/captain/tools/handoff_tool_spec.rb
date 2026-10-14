require 'rails_helper'

RSpec.describe Captain::Tools::HandoffTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:user) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:run_context) { Captain::Runtime::RunContext.new({ state: { conversation: { id: conversation.id } } }) }
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }

  describe '#description' do
    it 'returns the correct description' do
      expect(tool.description).to eq('Hand off the current conversation to a human team')
    end
  end

  describe '#parameters' do
    it 'returns the correct parameters' do
      # A handoff is silent for the customer, so the agent is not asked for a message.
      expect(tool.parameters.keys).to contain_exactly(:reason)
      expect(tool.parameters[:reason].name).to eq(:reason)
      expect(tool.parameters[:reason].type).to eq('string')
      expect(tool.parameters[:reason].description).to eq('Optional handoff reason for the human team')
      expect(tool.parameters[:reason].required).to be false
    end
  end

  describe '#perform' do
    context 'when conversation exists' do
      context 'with the former explicit consent option enabled' do
        before do
          assistant.update!(config: assistant.config.merge('handoff_requires_explicit_consent' => true))
        end

        it 'honors the model tool call without matching a list of customer phrases' do
          create(:message, account: account, inbox: inbox, conversation: conversation,
                           message_type: :incoming, content: 'Necesito hablar con una persona.')

          result = tool.perform(tool_context, reason: 'Customer asked for a person')

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to include(reason: 'Customer asked for a person')
        end

        it 'does not execute a disabled tool even when a prompt mentions handoff' do
          # Customer-facing agents always have handoff (owner decision); only an internal
          # assistant has it disabled, whatever its legacy per-agent switch says.
          assistant.update!(
            usage_mode: 'internal_assistant',
            description: 'Mention handoff as a concept, but do not enable its tool.',
            config: assistant.config.deep_merge('handoff_enabled' => false,
                                                'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } })
          )

          expect { tool.execute(tool_context, reason: 'Model tried to transfer') }
            .to raise_error(ArgumentError, 'Tool is not available for the current runtime policy')
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end
      end

      it 'leaves classification to the outcome job even if an old caller supplies a reason ID' do
        assistant.update!(
          config: assistant.config.to_h.deep_merge(
            'outcome_reason_settings' => {
              'handoff_reasons' => [
                { 'id' => 'billing_queue', 'label' => 'Support', 'active' => true },
                { 'id' => 'technical_queue', 'label' => 'Support', 'active' => true }
              ]
            }
          )
        )

        result = tool.perform(tool_context, outcome_reason_id: 'technical_queue', reason: 'The issue requires technical review.')

        expect(result).to be_a(RubyLLM::Tool::Halt)
        expect(run_context.context[:pending_human_handoff]).to include(reason: 'The issue requires technical review.')
        expect(run_context.context[:pending_human_handoff]).not_to have_key(:outcome_reason_id)
        expect(run_context.context[:pending_human_handoff]).not_to have_key(:status_reason)
      end

      it 'does not block handoff while its reporting reason is unknown' do
        assistant.update!(
          config: assistant.config.to_h.deep_merge(
            'outcome_reason_settings' => {
              'handoff_reasons' => [{ 'id' => 'other', 'label' => 'Other', 'active' => true }]
            }
          )
        )

        expect(tool.perform(tool_context, outcome_reason_id: 'other')).to be_a(RubyLLM::Tool::Halt)
        expect(run_context.context).to have_key(:pending_human_handoff)

        result = tool.perform(
          tool_context,
          outcome_reason_id: 'other',
          reason: 'The customer described an account-specific policy exception.'
        )

        expect(result).to be_a(RubyLLM::Tool::Halt)
        expect(run_context.context[:pending_human_handoff]).to include(
          reason: 'The customer described an account-specific policy exception.'
        )
      end

      it 'does not hand off when the assistant permission is disabled' do
        # The handoff permission is no longer a per-agent switch: customer-facing agents always
        # have it, and an internal assistant never does.
        assistant.update!(usage_mode: 'internal_assistant', config: assistant.config.to_h.deep_merge('handoff_enabled' => false))

        expect { tool.execute(tool_context, reason: 'The model tried to transfer') }
          .to raise_error(ArgumentError, 'Tool is not available for the current runtime policy')
        expect(run_context.context).not_to have_key(:pending_human_handoff)
      end

      it 'keeps handoff for a customer-facing agent even when its legacy per-agent switch is off' do
        assistant.update!(config: assistant.config.to_h.deep_merge('handoff_enabled' => false))

        expect(tool.execute(tool_context, reason: 'The customer asked for a person')).to be_a(RubyLLM::Tool::Halt)
        expect(run_context.context[:pending_human_handoff]).to include(reason: 'The customer asked for a person')
      end

      it 'carries a proven FAQ miss only from the current agent, and distinguishes a retrieval outage' do
        run_context.context[:captain_faq_outcome] = { assistant_id: assistant.id, result: 'not_found', unavailable: false }
        tool.perform(tool_context)
        expect(run_context.context[:pending_human_handoff][:outcome_signal]).to eq('faq_no_answer')

        run_context.context[:captain_faq_outcome][:unavailable] = true
        tool.perform(tool_context)
        expect(run_context.context[:pending_human_handoff]).not_to have_key(:outcome_signal)

        run_context.context[:captain_faq_outcome] = { assistant_id: assistant.id + 1, result: 'not_found', unavailable: false }
        tool.perform(tool_context)
        expect(run_context.context[:pending_human_handoff]).not_to have_key(:outcome_signal)
      end

      context 'with reason provided' do
        it 'stores pending handoff context and halts the runtime' do
          reason = 'Customer needs specialized support'
          status_reason = 'Needs agent'
          message = 'I will connect you with a human agent.'

          expect do
            result = tool.perform(tool_context, reason: reason, status_reason: status_reason, message: message)
            expect(result).to be_a(RubyLLM::Tool::Halt)
            expect(result.content).to eq("Conversation handed off to human support team (Reason: #{reason})")
          end.not_to change(Message, :count)

          # A message from an older tool call is accepted but never kept: the notice service writes the customer text.
          expect(run_context.context[:pending_human_handoff]).to include(reason: reason)
          expect(run_context.context[:pending_human_handoff]).not_to have_key(:message)
          expect(run_context.context[:pending_human_handoff]).not_to have_key(:status_reason)
        end

        it 'creates a conversation_bot_handoff reporting event' do
          expect do
            tool.perform(tool_context, reason: 'Customer needs specialized support')
          end.not_to change(ReportingEvent, :count)
        end

        it 'logs tool usage with reason' do
          reason = 'Customer needs help'
          expect(tool).to receive(:log_tool_usage).with(
            'tool_handoff',
            { conversation_id: conversation.id, reason: reason }
          )

          tool.perform(tool_context, reason: reason)
        end
      end

      context 'without reason provided' do
        it 'halts the runtime without creating messages' do
          expect do
            result = tool.perform(tool_context)
            expect(result).to be_a(RubyLLM::Tool::Halt)
            expect(result.content).to eq('Conversation handed off to human support team')
          end.not_to change(Message, :count)

          expect(run_context.context[:pending_human_handoff]).not_to have_key(:reason)
          expect(run_context.context[:pending_human_handoff]).to have_key(:timestamp)
        end

        it 'logs tool usage with default reason' do
          expect(tool).to receive(:log_tool_usage).with(
            'tool_handoff',
            { conversation_id: conversation.id, reason: 'Agent requested handoff' }
          )

          tool.perform(tool_context)
        end
      end

      context 'when handoff fails' do
        before do
          allow(tool).to receive(:request_handoff).and_raise(StandardError, 'Handoff error')

          exception_tracker = instance_double(ChatwootExceptionTracker)
          allow(ChatwootExceptionTracker).to receive(:new).and_return(exception_tracker)
          allow(exception_tracker).to receive(:capture_exception)
        end

        it 'returns error message' do
          result = tool.perform(tool_context, reason: 'Test')
          expect(result).to eq('ERROR: Failed to handoff conversation')
        end

        it 'captures exception' do
          exception_tracker = instance_double(ChatwootExceptionTracker)
          expect(ChatwootExceptionTracker).to receive(:new).with(instance_of(StandardError)).and_return(exception_tracker)
          expect(exception_tracker).to receive(:capture_exception)

          tool.perform(tool_context, reason: 'Test')
        end
      end
    end

    context 'when conversation does not exist' do
      let(:tool_context) { Struct.new(:state).new({ conversation: { id: 999_999 } }) }

      it 'returns error message' do
        result = tool.perform(tool_context, reason: 'Test')
        expect(result).to eq('Conversation not found')
      end

      it 'does not create a message' do
        expect do
          tool.perform(tool_context, reason: 'Test')
        end.not_to change(Message, :count)
      end
    end

    context 'when conversation state is missing' do
      let(:tool_context) { Struct.new(:state).new({}) }

      it 'returns error message' do
        result = tool.perform(tool_context, reason: 'Test')
        expect(result).to eq('Conversation not found')
      end
    end

    context 'when conversation id is nil' do
      let(:tool_context) { Struct.new(:state).new({ conversation: { id: nil } }) }

      it 'returns error message' do
        result = tool.perform(tool_context, reason: 'Test')
        expect(result).to eq('Conversation not found')
      end
    end
  end

  describe '#active?' do
    it 'returns true for public tools' do
      expect(tool.active?).to be true
    end
  end

  describe 'out of office message after handoff' do
    context 'when outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed. Please leave your email.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
      end

      it 'sends out of office message after handoff' do
        expect do
          tool.perform(tool_context, reason: 'Customer needs help')
        end.not_to(change { conversation.messages.template.count })
      end
    end

    context 'when within business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )
      end

      it 'does not send out of office message after handoff' do
        expect do
          tool.perform(tool_context, reason: 'Customer needs help')
        end.not_to(change { conversation.messages.template.count })
      end
    end

    context 'when no out of office message is configured' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: nil
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
      end

      it 'does not send out of office message' do
        expect do
          tool.perform(tool_context, reason: 'Customer needs help')
        end.not_to(change { conversation.messages.template.count })
      end
    end
  end
end
