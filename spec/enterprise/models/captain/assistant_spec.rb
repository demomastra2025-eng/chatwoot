require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  describe 'tool access' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'keeps the broader scenario tool catalog available by default' do
      expect(assistant.allowed_agent_tool_ids).to include('faq_lookup', 'handoff', 'add_private_note')
    end

    it 'keeps the direct agent runtime on faq and handoff by default' do
      expect(assistant.direct_agent_tool_ids).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'includes enabled custom tools in the assistant scope catalog by default' do
      custom_tool = create(:captain_custom_tool, account: account)

      expect(assistant.available_assistant_tool_ids).to include(custom_tool.slug)
      expect(assistant.allowed_assistant_tool_ids).to include(custom_tool.slug)
    end

    it 'keeps every built-in agent tool available in the assistant catalog' do
      missing_tool_ids = assistant.available_tool_ids - assistant.available_assistant_tool_ids

      expect(missing_tool_ids).to be_empty
      expect(assistant.available_assistant_tool_ids).to include('faq_lookup', 'create_deal', 'create_task', 'create_appointment')
    end

    it 'respects configured tool access for both scopes' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'agent' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            },
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation']
            }
          }
        }
      )

      expect(assistant.allowed_agent_tool_ids).to eq(['faq_lookup'])
      expect(assistant.direct_agent_tool_ids).to eq(['faq_lookup'])
      expect(assistant.allowed_assistant_tool_ids).to eq(['search_documentation'])
    end
  end

  describe '#agent_instructions' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'renders deal and task context using explicitly passed visible fields' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              deal: {
                'stage_name' => 'Negotiation'
              },
              task: {
                'status_name' => 'In progress'
              },
              visible_fields: {
                deal: ['stage_name'],
                task: ['status_name']
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Linked Deal Context')
      expect(rendered).to include('Stage Name: Negotiation')
      expect(rendered).to include('Linked Task Context')
      expect(rendered).to include('Status Name: In progress')
    end

    it 'renders appointment context using explicitly passed visible fields' do
      context_double = instance_double(
        Captain::Runtime::RunContext,
        context: {
          state: {
            assistant_config: { 'context_access' => {} },
            prompt_context: {
              appointment: {
                'status' => 'confirmed'
              },
              visible_fields: {
                appointment: ['status']
              }
            }
          }
        }
      )

      rendered = assistant.agent_instructions(context_double)

      expect(rendered).to include('Linked Appointment Context')
      expect(rendered).to include('Status: confirmed')
    end
  end
end
