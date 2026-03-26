require 'rails_helper'

describe AgentBots::FlowBuilder::RunnerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:contact) { conversation.contact }
  let(:agent_bot) do
    create(
      :agent_bot,
      account: account,
      bot_type: 'flow_builder',
      outgoing_url: nil,
      bot_config: bot_config
    )
  end

  before do
    create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
  end

  describe '#perform' do
    context 'when the graph contains a menu branch' do
      let(:bot_config) do
        {
          version: 2,
          flow: {
            drawflow: {
              Home: {
                data: {
                  trigger_root: {
                    id: 'trigger_root',
                    name: 'trigger',
                    data: { event: 'all_messages', keywords: [] },
                    class: 'trigger',
                    html: '',
                    inputs: {},
                    outputs: {
                      output_1: {
                        connections: [{ node: 'menu', output: 'input_1' }]
                      }
                    },
                    pos_x: 0,
                    pos_y: 0
                  },
                  menu: {
                    id: 'menu',
                    name: 'menu',
                    data: {
                      body: 'Choose a team',
                      invalid_reply_message: 'Reply with 1 or 2',
                      options: [
                        { id: 'sales', label: 'Sales', value: 'sales' },
                        { id: 'support', label: 'Support', value: 'support' }
                      ]
                    },
                    class: 'menu',
                    html: '',
                    inputs: {
                      input_1: {
                        connections: [{ node: 'trigger_root', input: 'output_1' }]
                      }
                    },
                    outputs: {
                      output_1: {
                        connections: [{ node: 'sales_reply', output: 'input_1' }]
                      },
                      output_2: {
                        connections: [{ node: 'support_reply', output: 'input_1' }]
                      }
                    },
                    pos_x: 0,
                    pos_y: 0
                  },
                  sales_reply: {
                    id: 'sales_reply',
                    name: 'message',
                    data: { body: 'Sales team will help you' },
                    class: 'message',
                    html: '',
                    inputs: {
                      input_1: {
                        connections: [{ node: 'menu', input: 'output_1' }]
                      }
                    },
                    outputs: { output_1: { connections: [] } },
                    pos_x: 0,
                    pos_y: 0
                  },
                  support_reply: {
                    id: 'support_reply',
                    name: 'message',
                    data: { body: 'Support team will help you' },
                    class: 'message',
                    html: '',
                    inputs: {
                      input_1: {
                        connections: [{ node: 'menu', input: 'output_2' }]
                      }
                    },
                    outputs: { output_1: { connections: [] } },
                    pos_x: 0,
                    pos_y: 0
                  }
                }
              }
            }
          }
        }
      end

      it 'stores waiting state and resumes from the selected output branch' do
        initial_message = create(
          :message,
          message_type: 'incoming',
          content: 'hello',
          sender: contact,
          account: account,
          inbox: inbox,
          conversation: conversation
        )

        expect do
          described_class.new(agent_bot: agent_bot, message: initial_message).perform
        end.to change { conversation.messages.outgoing.count }.by(1)

        state = conversation.reload.additional_attributes.dig(
          'agent_bot_runtime',
          'flow_builder',
          agent_bot.id.to_s
        )
        expect(state['waiting_for_node_id']).to eq('menu')
        expect(conversation.messages.outgoing.last.content).to include('1. Sales')

        reply_message = create(
          :message,
          message_type: 'incoming',
          content: '2',
          sender: contact,
          account: account,
          inbox: inbox,
          conversation: conversation
        )

        expect do
          described_class.new(agent_bot: agent_bot, message: reply_message).perform
        end.to change { conversation.messages.outgoing.count }.by(1)

        expect(
          conversation.reload.additional_attributes.dig(
            'agent_bot_runtime',
            'flow_builder',
            agent_bot.id.to_s
          )
        ).to be_nil
        expect(conversation.messages.outgoing.last.content).to eq('Support team will help you')
      end
    end

    context 'when the graph contains a condition branch' do
      let(:bot_config) do
        {
          version: 2,
          flow: {
            drawflow: {
              Home: {
                data: {
                  trigger_root: {
                    id: 'trigger_root',
                    name: 'trigger',
                    data: { event: 'all_messages', keywords: [] },
                    class: 'trigger',
                    html: '',
                    inputs: {},
                    outputs: {
                      output_1: {
                        connections: [{ node: 'condition_1', output: 'input_1' }]
                      }
                    },
                    pos_x: 0,
                    pos_y: 0
                  },
                  condition_1: {
                    id: 'condition_1',
                    name: 'condition',
                    data: {
                      field: 'message_text',
                      operator: 'contains',
                      value: 'support',
                      label_ids: []
                    },
                    class: 'condition',
                    html: '',
                    inputs: {
                      input_1: {
                        connections: [{ node: 'trigger_root', input: 'output_1' }]
                      }
                    },
                    outputs: {
                      output_1: {
                        connections: [{ node: 'support_message', output: 'input_1' }]
                      },
                      output_2: {
                        connections: [{ node: 'fallback_message', output: 'input_1' }]
                      }
                    },
                    pos_x: 0,
                    pos_y: 0
                  },
                  support_message: {
                    id: 'support_message',
                    name: 'message',
                    data: { body: 'Support matched' },
                    class: 'message',
                    html: '',
                    inputs: {
                      input_1: {
                        connections: [{ node: 'condition_1', input: 'output_1' }]
                      }
                    },
                    outputs: { output_1: { connections: [] } },
                    pos_x: 0,
                    pos_y: 0
                  },
                  fallback_message: {
                    id: 'fallback_message',
                    name: 'message',
                    data: { body: 'Fallback branch' },
                    class: 'message',
                    html: '',
                    inputs: {
                      input_1: {
                        connections: [{ node: 'condition_1', input: 'output_2' }]
                      }
                    },
                    outputs: { output_1: { connections: [] } },
                    pos_x: 0,
                    pos_y: 0
                  }
                }
              }
            }
          }
        }
      end

      it 'follows the matching yes branch' do
        message = create(
          :message,
          message_type: 'incoming',
          content: 'I need support',
          sender: contact,
          account: account,
          inbox: inbox,
          conversation: conversation
        )

        described_class.new(agent_bot: agent_bot, message: message).perform

        expect(conversation.messages.outgoing.last.content).to eq('Support matched')
      end
    end
  end
end
