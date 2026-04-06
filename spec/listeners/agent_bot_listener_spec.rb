require 'rails_helper'
describe AgentBotListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:agent_bot) { create(:agent_bot) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: user) }

  before do
    allow(SendReplyJob).to receive(:perform_later)
    allow(SendReplyJob).to receive_message_chain(:set, :perform_later)
  end

  describe '#message_created' do
    let(:event_name) { 'message.created' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, message: message) }
    let!(:message) do
      create(:message, message_type: 'outgoing',
                       account: account, inbox: inbox, conversation: conversation)
    end

    context 'when agent bot is not configured' do
      it 'does not send message to agent bot' do
        expect(AgentBots::WebhookJob).to receive(:perform_later).exactly(0).times
        listener.message_created(event)
      end
    end

    context 'when agent bot is configured' do
      it 'sends message to agent bot' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        expect(AgentBots::WebhookJob).to receive(:perform_later).with(agent_bot.outgoing_url,
                                                                      message.webhook_data.merge(event: 'message_created')).once
        listener.message_created(event)
      end

      it 'does not send message to agent bot if url is empty' do
        agent_bot = create(:agent_bot, outgoing_url: '')
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        expect(AgentBots::WebhookJob).not_to receive(:perform_later)
        listener.message_created(event)
      end

      context 'when conversation has a different assignee agent bot' do
        let!(:conversation_bot) { create(:agent_bot) }

        before do
          create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
          conversation.update!(assignee_agent_bot: conversation_bot, assignee: nil)
        end

        it 'sends message to both bots exactly once' do
          payload = message.webhook_data.merge(event: 'message_created')

          expect(AgentBots::WebhookJob).to receive(:perform_later).with(agent_bot.outgoing_url, payload).once
          expect(AgentBots::WebhookJob).to receive(:perform_later).with(conversation_bot.outgoing_url, payload).once

          listener.message_created(event)
        end
      end
    end
  end

  describe '#conversation_status_changed' do
    let(:event_name) { 'conversation.status_changed' }
    let(:changed_attributes) { { status: %w[open pending] } }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes) }

    context 'when agent bot is not configured' do
      it 'does not send webhook' do
        expect(AgentBots::WebhookJob).not_to receive(:perform_later)
        listener.conversation_status_changed(event)
      end
    end

    context 'when agent bot is configured on inbox' do
      it 'sends webhook with changed_attributes' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        expect(AgentBots::WebhookJob).to receive(:perform_later).with(
          agent_bot.outgoing_url,
          hash_including(event: 'conversation_status_changed', changed_attributes: anything)
        ).once
        listener.conversation_status_changed(event)
      end
    end

    context 'when conversation is assigned to an agent bot' do
      before do
        conversation.update!(assignee_agent_bot: agent_bot, assignee: nil)
      end

      it 'sends webhook to the assigned agent bot' do
        expect(AgentBots::WebhookJob).to receive(:perform_later).with(
          agent_bot.outgoing_url,
          hash_including(event: 'conversation_status_changed', changed_attributes: anything)
        ).once
        listener.conversation_status_changed(event)
      end
    end
  end

  describe '#conversation_updated' do
    let(:event_name) { 'conversation.updated' }

    context 'when agent bot is not configured' do
      let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

      it 'does not send webhook' do
        expect(AgentBots::WebhookJob).not_to receive(:perform_later)
        listener.conversation_updated(event)
      end
    end

    context 'when agent bot is configured on inbox' do
      let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

      it 'sends webhook to the inbox agent bot with changed_attributes' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        expect(AgentBots::WebhookJob).to receive(:perform_later).with(agent_bot.outgoing_url,
                                                                      conversation.webhook_data.merge(event: 'conversation_updated',
                                                                                                      changed_attributes: nil)).once
        listener.conversation_updated(event)
      end
    end

    context 'when conversation is assigned to an agent bot' do
      let!(:event) do
        Events::Base.new(event_name, Time.zone.now, conversation: conversation,
                                                    changed_attributes: { 'assignee_agent_bot_id' => [nil, agent_bot.id] })
      end

      before do
        conversation.update!(assignee_agent_bot: agent_bot, assignee: nil)
      end

      it 'sends webhook with changed_attributes to the assigned agent bot' do
        expected_changed_attributes = [{ 'assignee_agent_bot_id' => { previous_value: nil, current_value: agent_bot.id } }]
        expect(AgentBots::WebhookJob).to receive(:perform_later).with(agent_bot.outgoing_url,
                                                                      conversation.webhook_data.merge(
                                                                        event: 'conversation_updated',
                                                                        changed_attributes: expected_changed_attributes
                                                                      )).once
        listener.conversation_updated(event)
      end
    end
  end

  describe 'flow builder bots' do
    let!(:agent_bot) do
      create(
        :agent_bot,
        account: account,
        bot_type: 'flow_builder',
        outgoing_url: nil,
        bot_config: bot_config
      )
    end
    let!(:event) { Events::Base.new('message.created', Time.zone.now, message: message) }
    let!(:message) do
      create(
        :message,
        message_type: 'incoming',
        content: message_content,
        sender: conversation.contact,
        account: account,
        inbox: inbox,
        conversation: conversation
      )
    end

    before do
      create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
    end

    context 'when the flow sends a direct reply' do
      let(:message_content) { 'hello' }
      let(:bot_config) do
        {
          trigger: { event: 'all_messages' },
          steps: [
            {
              id: 'welcome',
              type: 'message',
              body: 'Hello from the bot'
            }
          ]
        }
      end

      it 'creates a native outgoing message from the agent bot' do
        expect { listener.message_created(event) }.to change { conversation.messages.outgoing.count }.by(1)

        outgoing_message = conversation.messages.outgoing.last

        expect(outgoing_message.content).to eq('Hello from the bot')
        expect(outgoing_message.sender).to eq(agent_bot)
      end
    end

    context 'when the flow waits for a menu reply' do
      let(:message_content) { initial_message_content }
      let(:initial_message_content) { 'start' }
      let(:bot_config) do
        {
          trigger: { event: 'all_messages' },
          steps: [
            {
              id: 'menu',
              type: 'menu',
              body: 'Choose a team',
              invalid_reply_message: 'Reply with 1 or 2',
              options: [
                { label: 'Sales', value: 'sales', target_step_id: 'sales' },
                { label: 'Support', value: 'support', target_step_id: 'support' }
              ]
            },
            {
              id: 'sales',
              type: 'message',
              body: 'Sales team will help you'
            },
            {
              id: 'support',
              type: 'message',
              body: 'Support team will help you'
            }
          ]
        }
      end

      it 'stores waiting state and resumes from the selected branch' do
        listener.message_created(event)

        state = conversation.reload.additional_attributes.dig('agent_bot_runtime', 'flow_builder', agent_bot.id.to_s)
        expect(state['waiting_for_step_id']).to eq('menu')
        expect(conversation.messages.outgoing.last.content).to include('1. Sales')

        reply_message = create(
          :message,
          message_type: 'incoming',
          content: '2',
          sender: conversation.contact,
          account: account,
          inbox: inbox,
          conversation: conversation
        )

        reply_event = Events::Base.new('message.created', Time.zone.now, message: reply_message)

        expect { listener.message_created(reply_event) }.to change { conversation.messages.outgoing.count }.by(1)

        expect(conversation.reload.additional_attributes.dig('agent_bot_runtime', 'flow_builder', agent_bot.id.to_s)).to be_nil
        expect(conversation.messages.outgoing.last.content).to eq('Support team will help you')
      end
    end
  end

  describe '#webwidget_triggered' do
    let(:event_name) { 'webwidget.triggered' }

    context 'when agent bot is configured' do
      it 'send message to agent bot URL' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)

        event = double
        allow(event).to receive(:data)
          .and_return(
            {
              contact_inbox: conversation.contact_inbox,
              event_info: { country: 'US' }
            }
          )
        expect(AgentBots::WebhookJob).to receive(:perform_later)
          .with(
            agent_bot.outgoing_url,
            conversation.contact_inbox.webhook_data.merge(event: 'webwidget_triggered', event_info: { country: 'US' })
          ).once

        listener.webwidget_triggered(event)
      end
    end
  end
end
