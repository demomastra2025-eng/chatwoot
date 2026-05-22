require 'rails_helper'

RSpec.describe Captain::Copilot::ChatService do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:user) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user) }
  let!(:copilot_message) do
    create(
      :captain_copilot_message, account: account, copilot_thread: copilot_thread
    )
  end
  let(:previous_history) { [{ role: copilot_message.message_type, content: copilot_message.message['content'] }] }

  let(:config) do
    { user_id: user.id, copilot_thread_id: copilot_thread.id, conversation_id: conversation.display_id }
  end

  # RubyLLM mocks
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_response) do
    instance_double(
      RubyLLM::Message,
      content: {
        'content' => 'Hey',
        'reasoning' => 'Test reasoning',
        'reply_suggestion' => false,
        'ui_actions' => []
      },
      input_tokens: 20,
      output_tokens: 10
    )
  end

  before do
    InstallationConfig.find_or_create_by(name: 'CAPTAIN_OPEN_AI_API_KEY') do |c|
      c.value = 'test-key'
    end

    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_thinking).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tool).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
    allow(mock_chat).to receive(:add_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_new_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_end_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_call).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_result).and_return(mock_chat)
    allow(mock_chat).to receive(:messages).and_return([])
    allow(mock_chat).to receive(:model).and_return(instance_double('RubyLLM::Model::Info', id: 'gpt-4.1-mini'))
    allow(mock_chat).to receive(:ask).and_return(mock_response)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
  end

  describe '#initialize' do
    it 'sets up the service with correct instance variables' do
      service = described_class.new(assistant, config)

      expect(service.assistant).to eq(assistant)
      expect(service.account).to eq(account)
      expect(service.user).to eq(user)
      expect(service.copilot_thread).to eq(copilot_thread)
      expect(service.previous_history).to eq(previous_history)
    end

    it 'builds messages with system message and account context' do
      service = described_class.new(assistant, config)
      messages = service.messages

      expect(messages.first[:role]).to eq('system')
      expect(messages.second[:role]).to eq('system')
      expect(messages.second[:content]).to include(account.id.to_s)
    end

    it 'filters copilot tools through assistant tool access' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['search_documentation']
            }
          }
        }
      )

      service = described_class.new(assistant, config)
      tool_classes = service.instance_variable_get(:@tools).map(&:class)

      expect(tool_classes).to contain_exactly(Captain::Tools::SearchDocumentationService)
    end

    it 'marks confirmation-required tools in the copilot system prompt' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['send_message_to_conversation']
            }
          }
        }
      )

      service = described_class.new(assistant, config)
      system_prompt = service.messages.first[:content]

      expect(system_prompt).to include('- send_message_to_conversation:')
      expect(system_prompt).to include('risk: high, requires operator confirmation')
    end

    it 'instantiates selected custom assistant tools through the native copilot wrapper' do
      custom_tool = create(:captain_custom_tool, account: account)

      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'assistant' => {
              'enabled' => true,
              'tool_ids' => [custom_tool.slug]
            }
          }
        }
      )

      service = described_class.new(assistant, config)
      tools = service.instance_variable_get(:@tools)

      expect(tools.map(&:class)).to contain_exactly(Captain::Tools::Copilot::CustomHttpTool)
      expect(tools.first.name).to eq(custom_tool.slug)
    end

    it 'instantiates shared agent tools in the assistant runtime catalog' do
      assistant.update!(
        config: {
          'context_access' => {},
          'tool_access' => {
            'assistant' => {
              'enabled' => true,
              'tool_ids' => ['faq_lookup']
            }
          }
        }
      )

      service = described_class.new(assistant, config)
      tools = service.instance_variable_get(:@tools)

      expect(tools.map(&:class)).to contain_exactly(Captain::Tools::Copilot::FaqLookupService)
      expect(tools.first.name).to eq('faq_lookup')
      expect(tools.first.instance_variable_get(:@conversation)).to eq(conversation)
    end

    it 'uses the account copilot model when configured' do
      account.update!(captain_models: { 'copilot' => 'gpt-5.2' })

      expect(RubyLLM).to receive(:chat).with(model: 'gpt-5.2').and_return(mock_chat)

      described_class.new(assistant, config).generate_response('Hello')
    end

    it 'applies thinking policy when configured for the account' do
      account.update!(captain_runtime: { 'copilot_thinking_effort' => 'high' })

      expect(mock_chat).to receive(:with_thinking).with(effort: 'high').and_return(mock_chat)

      described_class.new(assistant, config).generate_response('Hello')
    end

    it 'uses the copilot schema for structured responses' do
      expect(mock_chat).to receive(:with_schema).with(Captain::Llm::Schemas::CopilotResponse).and_return(mock_chat)

      described_class.new(assistant, config).generate_response('Hello')
    end

    it 'normalizes copilot UI actions before returning and persisting the assistant message' do
      allow(mock_response).to receive(:content).and_return(
        {
          content: 'Open the contact and reports.',
          reasoning: 'The operator needs quick navigation.',
          reply_suggestion: false,
          ui_actions: [
            { type: 'open_contact', label: '<b>Open contact</b>', target_id: contact.id.to_s },
            { type: 'click_dom', label: 'Unsafe DOM', target_id: '#delete' },
            { type: 'open_reports', label: 'Reports', target_id: '' }
          ]
        }
      )

      response = described_class.new(assistant, config).generate_response('Hello')
      expected_actions = [
        { 'type' => 'open_contact', 'label' => 'Open contact', 'target_id' => contact.id.to_s },
        { 'type' => 'open_reports', 'label' => 'Reports', 'target_id' => '' }
      ]

      expect(response['ui_actions']).to eq(expected_actions)
      expect(response.keys).not_to include(:ui_actions)
      expect(copilot_thread.copilot_messages.assistant.last.message['ui_actions']).to eq(expected_actions)
    end
  end

  describe '#generate_response' do
    let(:service) { described_class.new(assistant, config) }

    it 'adds user input to messages when present' do
      expect do
        service.generate_response('Hello')
      end.to(change { service.messages.count }.by(1))

      last_message = service.messages.last
      expect(last_message[:role]).to eq('user')
      expect(last_message[:content]).to eq('Hello')
    end

    it 'does not add user input to messages when blank' do
      expect do
        service.generate_response('')
      end.not_to(change { service.messages.count })
    end

    it 'returns the response from request_chat_completion' do
      result = service.generate_response('Hello')

      expect(result).to eq(
        {
          'content' => 'Hey',
          'reasoning' => 'Test reasoning',
          'reply_suggestion' => false,
          'ui_actions' => [],
          'usage' => {
            'prompt_tokens' => 20,
            'completion_tokens' => 10,
            'total_tokens' => 30
          }
        }
      )
    end

    it 'returns a blocked payload when moderation rejects the input' do
      account.update!(captain_runtime: { 'copilot_moderation' => true })
      allow(Llm::SafetyPolicy).to receive(:check!).and_raise(
        Llm::SafetyPolicy::UnsafeContentError.new(
          feature: :copilot,
          stage: :input,
          reason: :moderation_flagged,
          rule: :provider_moderation
        )
      )

      expect(service.generate_response('Hello')).to eq(
        {
          'content' => "I can't help with that request.",
          'reasoning' => 'Copilot input blocked by moderation policy',
          'reply_suggestion' => false,
          'ui_actions' => []
        }
      )
    end

    it 'returns a blocked payload when fail-closed moderation is unavailable' do
      account.update!(captain_runtime: { 'copilot_moderation' => true, 'moderation_failure_mode' => 'fail_closed' })
      allow(Llm::Config).to receive(:api_key).and_call_original
      allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return(nil)

      expect(service.generate_response('Hello')).to eq(
        {
          'content' => "I can't help with that request.",
          'reasoning' => 'Copilot input blocked because moderation policy is unavailable',
          'reply_suggestion' => false,
          'ui_actions' => []
        }
      )
    end

    it 'increments response usage for the account' do
      expect do
        service.generate_response('Hello')
      end.to(change { account.reload.custom_attributes['captain_responses_usage'].to_i }.by(1))
    end

    it 'increments token usage for the account' do
      expect do
        service.generate_response('Hello')
      end.to(change { account.reload.custom_attributes['captain_tokens_usage'].to_i }.by(30))
    end

    it 'persists assistant messages without transient usage metadata' do
      service.generate_response('Hello')

      persisted_message = copilot_thread.reload.copilot_messages.assistant.last.message

      expect(persisted_message).to include(
        'content' => 'Hey',
        'reasoning' => 'Test reasoning',
        'reply_suggestion' => false,
        'ui_actions' => []
      )
      expect(persisted_message).not_to have_key('usage')
    end
  end

  describe 'user setup behavior' do
    it 'sets user when user_id is present in config' do
      service = described_class.new(assistant, { user_id: user.id })
      expect(service.user).to eq(user)
    end

    it 'does not set user when user_id is not present in config' do
      service = described_class.new(assistant, {})
      expect(service.user).to be_nil
    end
  end

  describe 'message history behavior' do
    context 'when copilot_thread_id is present' do
      it 'finds the copilot thread and sets previous history from it' do
        service = described_class.new(assistant, { copilot_thread_id: copilot_thread.id })

        expect(service.copilot_thread).to eq(copilot_thread)
        expect(service.previous_history).to eq previous_history
      end
    end

    context 'when copilot_thread_id is not present' do
      it 'uses previous_history from config if present' do
        custom_history = [{ role: 'user', content: 'Custom message' }]
        service = described_class.new(assistant, { previous_history: custom_history })

        expect(service.copilot_thread).to be_nil
        expect(service.previous_history).to eq(custom_history)
      end

      it 'uses empty array if previous_history is not present in config' do
        service = described_class.new(assistant, {})

        expect(service.copilot_thread).to be_nil
        expect(service.previous_history).to eq([])
      end
    end
  end

  describe 'message building behavior' do
    it 'includes system message and account context' do
      service = described_class.new(assistant, {})
      messages = service.messages

      expect(messages.first[:role]).to eq('system')
      expect(messages.second[:role]).to eq('system')
      expect(messages.second[:content]).to include(account.id.to_s)
    end

    it 'includes previous history when present' do
      custom_history = [{ role: 'user', content: 'Custom message' }]
      service = described_class.new(assistant, { previous_history: custom_history })
      messages = service.messages

      expect(messages.count).to be >= 3
      expect(messages.any? { |m| m[:content] == 'Custom message' }).to be true
    end

    it 'includes current viewing history when conversation_id is present' do
      service = described_class.new(assistant, { conversation_id: conversation.display_id })
      messages = service.messages

      viewing_history = messages.find { |m| m[:content].include?('You are currently viewing the conversation') }
      expect(viewing_history).not_to be_nil
      expect(viewing_history[:content]).to include(conversation.display_id.to_s)
      expect(viewing_history[:content]).to include(contact.id.to_s)
    end
  end

  describe 'message persistence behavior' do
    context 'when copilot_thread is present' do
      it 'creates a copilot message with the response' do
        expect do
          described_class.new(assistant, { copilot_thread_id: copilot_thread.id }).generate_response('Hello')
        end.to change(CopilotMessage, :count).by(1)

        last_message = CopilotMessage.last
        expect(last_message.message_type).to eq('assistant')
        expect(last_message.message['content']).to eq('Hey')
      end
    end

    context 'when copilot_thread is not present' do
      it 'does not create a copilot message' do
        expect do
          described_class.new(assistant, {}).generate_response('Hello')
        end.not_to(change(CopilotMessage, :count))
      end
    end
  end
end
