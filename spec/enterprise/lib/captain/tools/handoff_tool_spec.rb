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

  def expect_consent_denied(result)
    expect(result).to include(
      success: false,
      error: described_class::CONSENT_REQUIRED_ERROR,
      retryable: false,
      audit: include(failure_stage: 'authorization', failure_reason: 'handoff_not_authorized')
    )
  end

  describe '#description' do
    it 'returns the correct description' do
      expect(tool.description).to eq('Hand off the current conversation to a human team')
    end
  end

  describe '#parameters' do
    it 'returns the correct parameters' do
      expect(tool.parameters.keys).to include(:reason, :status_reason, :message)
      expect(tool.parameters[:reason].name).to eq(:reason)
      expect(tool.parameters[:reason].type).to eq('string')
      expect(tool.parameters[:reason].description).to eq('Optional handoff reason for the human team')
      expect(tool.parameters[:reason].required).to be false
      expect(tool.parameters[:status_reason]).to have_attributes(type: 'string', required: false)
      expect(tool.parameters[:message]).to have_attributes(type: 'string', required: false)
    end
  end

  describe '#perform' do
    context 'when conversation exists' do
      context 'when explicit consent is required' do
        let(:create_triggering_message) do
          lambda do |content, **attributes|
            message = create(
              :message,
              account: account,
              inbox: inbox,
              conversation: conversation,
              message_type: :incoming,
              content: content,
              **attributes
            )
            run_context.context[:state][:captain_response_fence] = { last_message_id: message.id }
            message
          end
        end

        before do
          assistant.update!(config: assistant.config.merge(
            'handoff_requires_explicit_consent' => true,
            'handoff_consent_reason' => 'Запрос пользователя на помощь сотрудника.'
          ))
        end

        authorized_emergency_cases = [
          'У меня сильная боль в груди.',
          'У меня сильные боли в груди.',
          'Я не умираю, но у меня сильные боли в груди.',
          'Я не умираю, но у меня сильная боль в груди.',
          'Я не умираю, но у меня сильное кровотечение.',
          'Я не умираю, но не могу дышать.',
          'Я задыхаюсь.',
          'Пациент без сознания.',
          'Она потеряла сознание.',
          'Я хочу покончить с собой.'
        ]
        denied_emergency_cases = [
          'У меня нет сильных болей в груди.',
          'У меня не сильные боли в груди.',
          'Сильных болей в груди нет.',
          'У меня нет сильной боли в груди.',
          'У меня не сильная боль в груди.',
          'Сильной боли в груди нет.',
          'Я не умираю, просто хочу уточнить информацию.',
          'Я не задыхаюсь.',
          'Я не хочу покончить с собой.',
          'Я не пытаюсь убить себя.'
        ]

        authorized_emergency_cases.each do |content|
          it "authorizes: #{content}", :emergency_language_matrix do
            create_triggering_message.call(content)

            result = tool.perform(tool_context)

            expect(result).to be_a(RubyLLM::Tool::Halt)
            expect(run_context.context[:pending_human_handoff]).to be_present
          end
        end

        denied_emergency_cases.each do |content|
          it "denies: #{content}", :emergency_language_matrix do
            create_triggering_message.call(content)

            result = tool.perform(tool_context)

            expect_consent_denied(result)
            expect(run_context.context).not_to have_key(:pending_human_handoff)
          end
        end

        it 'blocks a family information request without consent' do
          create_triggering_message.call('Подскажите порядок для меня и ребёнка. Ничего не записывайте.')

          result = tool.perform(
            tool_context, reason: 'Family request', status_reason: 'needs_human', message: 'Connecting you.'
          )

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'blocks a new scheduling constraint after a handoff question' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Хотите, передам вопрос сотруднику?')
          create_triggering_message.call('Покажите только варианты позже 17:00.')

          result = tool.perform(tool_context, reason: 'Lookup failed')

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'allows a direct request for a human and normalizes internal fields' do
          create_triggering_message.call('Соедините меня с сотрудником.')

          result = tool.perform(
            tool_context, reason: 'Model supplied reason', status_reason: 'needs_human', message: 'Передаю сотруднику.'
          )

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to include(
            reason: assistant.handoff_consent_reason_value,
            message: 'Передаю сотруднику.'
          )
          expect(run_context.context[:pending_human_handoff]).not_to have_key(:status_reason)
          expect(run_context.context[described_class::AUTHORIZED_CONTEXT_KEY]).to be true
        end

        it 'blocks a negated handoff request' do
          create_triggering_message.call('Не соединяйте меня с сотрудником.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
          expect(run_context.context).not_to have_key(described_class::AUTHORIZED_CONTEXT_KEY)
        end

        it 'blocks a negated operator transfer request without mutating the conversation' do
          create_triggering_message.call('Не передавайте оператору.')
          original_status = conversation.status

          expect do
            result = tool.perform(tool_context)

            expect_consent_denied(result)
          end.not_to change(Message, :count)

          expect(conversation.reload.status).to eq(original_status)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
          expect(run_context.context).not_to have_key(described_class::AUTHORIZED_CONTEXT_KEY)
        end

        it 'blocks a negated request to speak with an operator' do
          create_triggering_message.call('Я не хочу поговорить с оператором.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'blocks a negated request to contact a doctor' do
          create_triggering_message.call('Я не хочу связаться с врачом.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'allows an independent direct request after a negated transfer clause' do
          create_triggering_message.call('Я не хочу поговорить с оператором, но соедините меня с врачом.')

          result = tool.perform(tool_context)

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to be_present
        end

        it 'blocks an informational question about contacting a doctor' do
          create_triggering_message.call('Как связаться с врачом?')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'allows a standalone affirmative answer to the immediately preceding handoff offer' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Хотите, передам вопрос сотруднику?')
          create_triggering_message.call('Да, пожалуйста')

          result = tool.perform(tool_context, reason: 'Model supplied reason')

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff][:reason]).to eq(assistant.handoff_consent_reason_value)
        end

        it 'allows the production consent after an unrelated negation in the preceding sentence' do
          create(
            :message,
            account: account,
            inbox: inbox,
            conversation: conversation,
            message_type: :outgoing,
            sender: assistant,
            content: 'По стоимости я сейчас не могу подтвердить точную цену. Передать диалог сотруднику?'
          )
          create_triggering_message.call('Да пожалуйста')

          result = tool.perform(tool_context, reason: 'Model supplied reason')

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to include(
            reason: assistant.handoff_consent_reason_value
          )
          expect(run_context.context[described_class::AUTHORIZED_CONTEXT_KEY]).to be true
        end

        it 'blocks an affirmative answer after a negated transfer statement' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Я не могу соединить вас с оператором.')
          create_triggering_message.call('Да')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'blocks an affirmative answer after a statement that was not a handoff offer' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Врач принимает сегодня до 18:00.')
          create_triggering_message.call('Да')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
          expect(run_context.context).not_to have_key(described_class::AUTHORIZED_CONTEXT_KEY)
        end

        it 'blocks an affirmative answer when another public message followed the handoff offer' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Хотите, передам вопрос сотруднику?')
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                           private: false, content: 'Сначала уточните удобное время.')
          create_triggering_message.call('Да')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'allows a conservative emergency request without separate consent' do
          create_triggering_message.call('Сейчас сильная боль в груди, не могу дышать.')

          result = tool.perform(tool_context, reason: 'Emergency')

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff][:reason]).to eq(assistant.handoff_consent_reason_value)
        end

        it 'allows a polite direct request phrased with a negative question' do
          create_triggering_message.call('Не могли бы вы соединить меня с оператором?')

          result = tool.perform(tool_context)

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to be_present
        end

        it 'blocks a negated emergency statement' do
          create_triggering_message.call('Я не умираю, просто хочу уточнить информацию.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'blocks a negated self-harm intent statement' do
          create_triggering_message.call('Я не хочу покончить с собой.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'blocks a negated self-harm attempt statement' do
          create_triggering_message.call('Я не пытаюсь убить себя.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'preserves an independent breathing emergency after a negated emergency clause' do
          create_triggering_message.call('Я не умираю, но не могу дышать.')

          result = tool.perform(tool_context)

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to be_present
        end

        it 'preserves an independent bleeding emergency after a negated emergency clause' do
          create_triggering_message.call('Я не умираю, но у меня сильное кровотечение.')

          result = tool.perform(tool_context)

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to be_present
        end

        it 'blocks a naturally phrased negated bleeding emergency' do
          create_triggering_message.call('У меня нет сильного кровотечения.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'blocks a negated chest pain emergency' do
          create_triggering_message.call('У меня не сильная боль в груди.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'fails closed when the response fence is absent' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                           content: 'Соедините меня с сотрудником.')

          result = tool.perform(tool_context)

          expect_consent_denied(result)
          expect(run_context.context).not_to have_key(:pending_human_handoff)
        end

        it 'uses chronological order when message ids were inserted out of order' do
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Хотите, передам вопрос сотруднику?', created_at: 1.minute.ago)
          create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing,
                           sender: assistant, content: 'Старое служебное сообщение.', created_at: 2.minutes.ago)
          create_triggering_message.call('Да')

          result = tool.perform(tool_context)

          expect(result).to be_a(RubyLLM::Tool::Halt)
          expect(run_context.context[:pending_human_handoff]).to be_present
        end
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

          expect(run_context.context[:pending_human_handoff]).to include(
            reason: reason,
            status_reason: status_reason,
            message: message
          )
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
