require 'rails_helper'

RSpec.describe Captain::Assistant::HandoffClaim do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { Captain::Assistant::AgentRunnerService.new(assistant: assistant) }

  before do
    allow(service).to receive(:moderate_output!)
    allow(service).to receive(:run_finalization_only_retry).and_raise('Unexpected paid finalization retry')
  end

  def process(text, context = {}, **output)
    result = Captain::Runtime::Result.new(output: { 'response' => text }.merge(output.stringify_keys), context: context)
    service.send(:process_agent_result, result)
  end

  [
    'Передала ваш запрос старшему администратору.',
    'Ваше обращение уже передано сотруднику.',
    'Переключаю вас на оператора.',
    'Передам ваш запрос сотруднику.',
    'Сұрауыңызды қызметкерге жібердім.',
    'Әкімшіге тапсырамын.',
    'I have transferred your request to an administrator.',
    "I've transferred your request to an operator.",
    "I'll transfer your request to staff.",
    'Your request has been transferred to an operator.',
    'I have not transferred the request to staff; I will connect you to a human.',
    'If you approve, I will transfer your request to staff; I have transferred your request to an operator.',
    'Если вы подтвердите, я передам запрос сотруднику; я уже передала запрос оператору.',
    'Я не передала запрос сотруднику; передам оператору.',
    'Я не передала запрос сотруднику, но я передам оператору.',
    'После вашего подтверждения я уже передала запрос сотруднику.',
    "I've transferred your request to staff after your approval.",
    'Растағаннан кейін қызметкерге жібердім.',
    'I will forward your request to staff.'
  ].each do |claim|
    it "blocks an unsupported affirmative claim: #{claim}" do
      expect(Captain::Tools::HandoffTool).not_to receive(:new)
      response = process(claim)
      expect(response).to include(
        'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
        'error_class' => 'Captain::Assistant::AgentRunnerService::SemanticOutputError',
        'error_message' => 'Model output claimed staff transfer without current-turn handoff evidence'
      )
      expect(response['handoff_tool_called']).not_to be(true)
    end
  end

  [
    'Могу передать ваш запрос сотруднику после вашего подтверждения.',
    'После вашего подтверждения передам запрос сотруднику.',
    'Передам запрос сотруднику, если вы подтвердите.',
    'Передать ваш запрос сотруднику?',
    'Передам сотруднику?',
    'Я не передала запрос сотруднику.',
    'Если вы передали вопрос менеджеру, дождитесь ответа.',
    'Когда вы передали вопрос менеджеру, он начал проверку.',
    'Они уже передали запрос сотруднику.',
    'В инструкции указано: запрос передан сотруднику.',
    'Если запрос передан сотруднику, дождитесь ответа.',
    'Оператор написал: «Передала запрос сотруднику». Уточните вопрос.',
    'Запишу вас на консультацию к специалисту.',
    'Специалист ответит на вопрос о лечении.',
    'Растағаннан кейін қызметкерге жіберемін.',
    'Can I transfer your request to staff?',
    'I will forward your request to staff after your approval.',
    "I'll transfer your request to staff after your approval.",
    'If your request has been transferred to an operator, please wait.',
    'If you approve, I will transfer your request to staff.',
    'Once you confirm, I will forward your request to staff.',
    'When you confirm, I will transfer your request to staff.',
    'After your approval, I will transfer your request to staff.',
    'Если вы подтвердите, я передам запрос сотруднику.',
    'Когда вы подтвердите, я передам запрос сотруднику.',
    'После вашего подтверждения, я передам запрос сотруднику.',
    'I have not transferred your request to staff.'
  ].each do |text|
    it "preserves a request, conditional proposal or quotation: #{text}" do
      expect(process(text)['response']).to eq(text)
    end
  end

  it 'does not accept a stale flag, a task/note pair, historical handoff or model-authored authorization as evidence' do
    contexts = [
      { captain_v2_handoff_tool_called: true },
      { pending_human_handoff: { reason: 'stale' } },
      { captain_v2_completed_tool_results: [{ tool_name: 'create_task', success: true }, { tool_name: 'add_private_note', success: true }] },
      { state: { captain_v2_handoff_tool_called: true, pending_human_handoff: { reason: 'previous turn' } } },
      { conversation_history: [{ role: :assistant, content: 'Передала запрос сотруднику.', handoff_tool_called: true }] }
    ]
    contexts.each do |context|
      response = process('Передала запрос сотруднику.', context, handoff_authorized: true, handoff_tool_called: true)
      expect(response['response']).to eq(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE)
    end
  end

  it 'accepts the current authorized handoff and preserves a council handoff without fabricating the tool flag' do
    response = process('Передала запрос сотруднику.', { captain_v2_handoff_tool_called: true,
                                                        pending_human_handoff: { reason: 'Current authorized handoff' } })
    expect(response).to include('response' => 'conversation_handoff', 'handoff_tool_called' => true, 'handoff_authorized' => true)
    council = process('Передала запрос сотруднику.', { council_handoff: { reason: 'Current unresolved part' } })
    expect(council).to include('response' => 'Передала запрос сотруднику.', 'handoff_tool_called' => false)
    expect(council['council_handoff']).to be_present
  end

  it 'retains the technical failure system handoff without needing a handoff tool invocation' do
    response = process('Передала запрос сотруднику.', { technical_failure: { tool: 'create_appointment', reason: 'timeout', stage: 'execution' } })
    expect(response).to include('response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
                                'error_class' => Captain::Assistant::AgentRunnerService::TECHNICAL_FAILURE_ERROR_CLASS)
    expect(response['handoff_tool_called']).not_to be(true)
  end

  it 'keeps suggestion approval proposals as drafts but does not let a pending approval justify a completed claim' do
    allow(service).to receive(:suggestion_run?).and_return(true)
    allow(service).to receive(:flag_draft!)
    pending = { captain_suggestion_pending_actions: [{ tool_id: 'handoff', status: 'pending' }] }
    proposal = 'После вашего подтверждения передам запрос сотруднику.'
    expect(process(proposal, pending)['response']).to eq(proposal)
    expect(process('Передала запрос сотруднику.', pending)['response']).to eq(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE)
  end
end
