require 'rails_helper'

RSpec.describe Captain::ShadowTraining::RunJob do
  let(:account) { create(:account, internal_attributes: { 'captain_shadow_training' => 'clinic' }) }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Айгерим', last_name: 'Ахметова', phone_number: '+77015556677') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let!(:assistant) { create(:captain_assistant, account: account, description: 'Отвечай по проверенным данным. CANONICAL_RULE') }
  let!(:service) { create(:scheduling_service, account: account, name: 'Консультация', base_price: 15_000) }
  let(:moment) { Time.current.change(usec: 0) }
  let!(:inbound) do
    create(:message, conversation: conversation, sender: contact, content: 'Сколько стоит консультация?', created_at: moment)
  end
  let(:reply) do
    create(:message, conversation: conversation, sender: user, message_type: :outgoing,
                     content: 'Консультация стоит 15000. HUMAN_TARGET_ONLY', created_at: moment + 1.second)
  end
  let(:capture) { Captain::ShadowTraining::CaptureService.call(reply) }
  let(:verdict) do
    {
      'verdict' => 'discrepancy', 'explanation' => 'Различается цена, источник — каталог.',
      'discrepancies' => [{ 'description' => 'AI указал 20000 вместо 15000.', 'source_refs' => ["service:#{service.id}"] }],
      'faq_candidates' => [{ 'question' => 'Сколько стоит консультация?', 'answer' => 'Консультация стоит 15000.',
                             'source_refs' => ["service:#{service.id}"] }]
    }
  end

  around do |example|
    with_modified_env(CAPTAIN_SHADOW_JUDGE_ORIGIN: 'http://127.0.0.1:18080', CAPTAIN_SHADOW_JUDGE_REGION: nil) { example.run }
  end

  before do
    stub_request(:get, 'http://127.0.0.1:18080/health').to_return(status: 200, body: '{"status":"ok"}')
    allow(Llm::SafetyPolicy).to receive(:check!)
    allow(Llm::Runtime).to receive(:chat).and_return(Struct.new(:content).new({ 'response' => 'Консультация стоит 20000.' }))
  end

  def stub_judge(value = verdict)
    stub_request(:post, 'http://127.0.0.1:18080/completion')
      .to_return(status: 200, body: JSON.generate(content: JSON.generate(value)))
  end

  def sdk_context(max_retries:)
    RubyLLM.context do |config|
      config.openrouter_api_key = 'synthetic-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
      config.max_retries = max_retries
      config.retry_interval = 0
      config.retry_interval_randomness = 0
    end
  end

  def enable_explicit_consent
    Captain::AccountSettings.new(account).update!('safety' => { 'require_explicit_ai_consent' => true })
    contact.update!(custom_attributes: { 'ai_consent_status' => 'granted' })
  end

  def revoke_consent
    Contact.find(contact.id).update!(custom_attributes: { 'ai_consent_status' => 'declined' })
  end

  # Full integration invariant: source, generation, comparison and output isolation are verified together.
  # rubocop:disable RSpec/MultipleExpectations
  it 'runs the synthetic pair through the gateway and native local judge into two pending candidates without live effects' do
    run = capture
    judge = stub_judge
    messages_before = conversation.messages.count
    expect(Captain::AssistantResponse).not_to receive(:create!)
    expect(Captain::ReplySuggestion::RequestStore).not_to receive(:create!)
    expect(Captain::ReplySuggestion::ActionApprovalService).not_to receive(:new)
    request_options = hash_including(feature: :assistant, assistant: assistant, account: account,
                                     tools: [], server_tools: [], tool_choice: 'none')
    expect(Llm::Runtime).to receive(:chat).once.with(request_options) do |**request|
      expect(request.fetch(:messages).to_json).to include('CANONICAL_RULE', '15000')
      expect(request.fetch(:messages).to_json).not_to include('HUMAN_TARGET_ONLY')
      Struct.new(:content).new({ 'response' => 'Консультация стоит 20000.' })
    end

    described_class.perform_now(run.id)
    described_class.perform_now(run.id)

    expect(run.reload.status).to eq('completed')
    expect(run.candidates.pluck(:kind, :status)).to contain_exactly(%w[faq pending], %w[regression pending])
    expect(run.candidates.all? { |candidate| candidate.proposal['operator_is_ground_truth'] == false }).to be true
    expect(run.snapshot['limitations']).to include('after_reply_facts', 'no_live_actions', 'time_variance')
    expect(conversation.messages.count).to eq(messages_before)
    expect(judge).to have_been_requested.once
  end

  # rubocop:enable RSpec/MultipleExpectations

  it 'captures a human message from the Captain listener without launching generation inline' do
    expect(Llm::Runtime).not_to receive(:chat)
    allow(Captain::ReplySuggestion::StickyAgent::ManualReply).to receive(:mark!)
    allow(Captain::ReplySuggestion::DismissalTracker).to receive(:message_created)
    event = Events::Base.new(:message_created, Time.current, message: reply)
    expect { CaptainListener.instance.message_created(event) }.to change(Captain::ShadowTraining::Run, :count).by(1)
  end

  it 'does not let a prior automated user message consume the human pair' do
    create(:message, conversation: conversation, sender: user, message_type: :outgoing,
                     content_attributes: { automation_rule_id: 123 }, created_at: moment + 0.5.seconds)
    expect(capture.human_message_id).to eq(reply.id)
  end

  it 'does not generate or queue anything for an incoming event or a disabled account' do
    expect(described_class).not_to receive(:perform_later)
    expect(Captain::ShadowTraining::CaptureService.call(inbound)).to be_nil
    account.update!(internal_attributes: {})
    expect(capture).to be_nil
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'captures only the first human reply even when listener events arrive in reverse order' do
    first = reply
    second = create(:message, conversation: conversation, sender: user, message_type: :outgoing, created_at: moment + 2.seconds)
    expect(Captain::ShadowTraining::CaptureService.call(second)).to be_nil
    expect(capture.id).to eq(Captain::ShadowTraining::CaptureService.call(first).id)
    expect(Captain::ShadowTraining::Run.count).to eq(1)
  end

  it 'includes all consecutive unanswered inputs and excludes target and later messages from the frozen history' do
    previous = create(:message, conversation: conversation, sender: contact, content: 'Ещё вопрос о подготовке', created_at: moment - 1.second)
    create(:message, conversation: conversation, sender: user, message_type: :outgoing, private: true,
                     content: 'PRIVATE_NOTE_ONLY', created_at: moment - 2.seconds)
    reply
    create(:message, conversation: conversation, sender: contact, content: 'LATER_INPUT_ONLY', created_at: moment + 2.seconds)
    run = capture

    expect(run.snapshot['history'].pluck('message_id')).to eq([previous.id, inbound.id])
    expect(run.snapshot.to_json).not_to include('HUMAN_TARGET_ONLY', 'LATER_INPUT_ONLY', 'PRIVATE_NOTE_ONLY')
    reply.update!(content: 'EDITED_TARGET')
    expect(run.reload.human_reply).to include('HUMAN_TARGET_ONLY')
  end

  it 'never sends another account catalog or target reply to generation' do
    create(:scheduling_service, name: 'OTHER_ACCOUNT_SECRET_CATALOG')
    run = capture
    expect(run.snapshot.to_json).not_to include('OTHER_ACCOUNT_SECRET_CATALOG', 'HUMAN_TARGET_ONLY')
    foreign_user = create(:user)
    reply.update!(sender: foreign_user)
    expect(Captain::ShadowTraining::CaptureService.call(reply)).to be_nil
  end

  it 'rejects private, failed, automated and imported user messages' do
    [
      { private: true }, { status: :failed }, { content_attributes: { automation_rule_id: 123 } },
      { content_attributes: { imported_history: true } }, { content_attributes: { touch_id: 123 } }
    ].each do |attributes|
      reply.update!(**attributes)
      expect(Captain::ShadowTraining::CaptureService.call(reply)).to be_nil
      reply.update!(private: false, status: :sent, content_attributes: {})
    end
  end

  it 'uses the existing consent gate without prompting or sending a patient message' do
    reply
    Captain::AccountSettings.new(account).update!('safety' => { 'require_explicit_ai_consent' => true })
    expect(Compliance::ExplicitAiConsentGate).not_to receive(:evaluate_incoming!)
    expect { capture }.not_to change(Captain::ShadowTraining::Run, :count)
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'rechecks consent after enqueue and before any generation' do
    run = capture
    Captain::AccountSettings.new(account).update!('safety' => { 'require_explicit_ai_consent' => true })
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('skipped')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'does not pay for generation when no local judge endpoint is configured' do
    run = capture
    with_modified_env(CAPTAIN_SHADOW_JUDGE_ORIGIN: nil) { described_class.perform_now(run.id) }
    expect(run.reload.status).to eq('awaiting_comparison')
    expect(run.shadow_reply).to be_nil
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'does not pay for generation or routing when the configured local judge is down' do
    run = capture
    stub_request(:get, 'http://127.0.0.1:18080/health').to_return(status: 503, body: '{"status":"loading model"}')
    described_class.perform_now(run.id)
    expect(run.reload.error_code).to eq('local_judge_not_ready')
    expect(run.status).to eq('awaiting_comparison')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'preflights immutable oversized input before paid routing or generation and does not retry it automatically' do
    create(:captain_assistant, account: account, routing_description: 'Другие услуги')
    assistant.update!(routing_description: 'Консультации')
    reply.update!(content: 'x' * 96_000)
    run = capture
    expect(Captain::Runtime::DecisionRouter).not_to receive(:new)
    described_class.perform_now(run.id)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('pending_input')
    expect(run.error_code).to eq('comparison_input_too_large')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'holds more than twenty unanswered messages rather than learning from an incomplete question' do
    20.times do |index|
      create(:message, conversation: conversation, sender: contact, content: "Вопрос #{index}", created_at: moment - (index + 1).seconds)
    end
    run = capture
    expect(run.snapshot['history_metadata']).to include('trailing_unanswered_count' => 21, 'unanswered_overflow' => true)
    expect(Captain::Runtime::DecisionRouter).not_to receive(:new)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('pending_input')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'holds an oversized complete history even though every individual message fits native limits' do
    19.times do |index|
      create(:message, conversation: conversation, sender: contact, content: 'x' * 4000, created_at: moment - (index + 1).seconds)
    end
    run = capture
    expect(run.snapshot['history_metadata']['unanswered_overflow']).to be false
    expect(Captain::Runtime::DecisionRouter).not_to receive(:new)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('pending_input')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'rechecks actual persisted enrollment after health before paid routing or generation' do
    create(:captain_assistant, account: account, routing_description: 'Другие услуги')
    assistant.update!(routing_description: 'Консультации')
    run = capture
    stub_request(:get, 'http://127.0.0.1:18080/health').to_return do
      Account.find(account.id).update!(internal_attributes: {})
      { status: 200, body: '{"status":"ok"}' }
    end
    expect(Captain::Runtime::DecisionRouter).not_to receive(:new)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('skipped')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'stops before comparison when real consent is revoked in another instance during generation' do
    Captain::AccountSettings.new(account).update!('safety' => { 'require_explicit_ai_consent' => true })
    contact.update!(custom_attributes: { 'ai_consent_status' => 'granted' })
    run = capture
    allow(Llm::Runtime).to receive(:chat) do
      Contact.find(contact.id).update!(custom_attributes: { 'ai_consent_status' => 'declined' })
      Struct.new(:content).new({ 'response' => 'Цена 20000' })
    end
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('skipped')
    expect(run.shadow_reply).to be_nil
    expect(a_request(:post, 'http://127.0.0.1:18080/completion')).not_to have_been_made
  end

  it 'aborts the real native Decisions fallback before a second HTTP after persisted consent revocation' do
    enable_explicit_consent
    create(:captain_assistant, account: account, routing_description: 'Другие услуги')
    assistant.update!(routing_description: 'Консультации')
    run = capture
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('synthetic-key')
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.example/api/v1')
    allow(Llm::DecisionChain).to receive(:models).with(:agent_routing).and_return(%w[inception/mercury-decide microsoft/microsoft-decision-1])
    endpoint = 'https://openrouter.example/api/alpha/decisions'
    first = stub_request(:post, endpoint).with { |request| JSON.parse(request.body)['model'] == 'inception/mercury-decide' }
                                         .to_return do
      revoke_consent
      { status: 503, body: '{"error":{"message":"synthetic unavailable"}}' }
    end
    second = stub_request(:post, endpoint).with { |request| JSON.parse(request.body)['model'] == 'microsoft/microsoft-decision-1' }
                                          .to_return(status: 200, body: '{}')

    expect { described_class.perform_now(run.id) }.not_to raise_error
    expect(run.reload.status).to eq('skipped')
    expect(first).to have_been_requested.once
    expect(second).not_to have_been_requested
  end

  it 'aborts the SDK inner Faraday retry before its second HTTP and contains the signal inside the job' do
    enable_explicit_consent
    run = capture
    context = sdk_context(max_retries: 2)
    connection = RubyLLM::Connection.new(RubyLLM::Providers::OpenRouter.new(context.config), context.config)
    wire = stub_request(:post, 'https://openrouter.example/api/v1/chat/completions').to_return do
      revoke_consent
      { status: 503, body: '{"error":{"message":"synthetic unavailable"}}', headers: { 'Content-Type' => 'application/json' } }
    end.then.to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    allow(Llm::Runtime).to receive(:chat) do |**request|
      connection.post('chat/completions', { model: 'synthetic', messages: request.fetch(:messages) })
      Struct.new(:content).new({ 'response' => 'Цена 20000' })
    end

    expect { described_class.perform_now(run.id) }.not_to raise_error
    expect(run.reload.status).to eq('skipped')
    expect(wire).to have_been_requested.once
    expect(run.shadow_reply).to be_nil
  end

  it 'aborts schema repair before its second actual HTTP after the first invalid response revokes consent' do
    enable_explicit_consent
    run = capture
    context = sdk_context(max_retries: 0)
    chat = context.chat(model: 'openai/gpt-5.4-mini', provider: :openrouter, assume_model_exists: true)
    chat.instance_variable_set(Llm::StructuredOutputPolicy::CHAT_SCHEMA_IVAR, Captain::ResponseSchema)
    connection = RubyLLM::Connection.new(RubyLLM::Providers::OpenRouter.new(context.config), context.config)
    wire = stub_request(:post, 'https://openrouter.example/api/v1/chat/completions').to_return do
      revoke_consent
      { status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' } }
    end
    allow(Llm::Runtime).to receive(:chat) do |**request|
      Llm::StructuredOutputPolicy.execute(chat: chat) do
        connection.post('chat/completions', { model: 'synthetic', messages: request.fetch(:messages) })
        Struct.new(:content).new('not JSON')
      end
    end

    expect { described_class.perform_now(run.id) }.not_to raise_error
    expect(run.reload.status).to eq('skipped')
    expect(wire).to have_been_requested.once
    expect(run.shadow_reply).to be_nil
  end

  it 'aborts the actual ChatRequestRunner retry before its second HTTP with SDK retries disabled' do
    enable_explicit_consent
    run = capture
    context = sdk_context(max_retries: 0)
    chat = context.chat(model: 'openai/gpt-5.4-mini', provider: :openrouter, assume_model_exists: true)
    wire = stub_request(:post, 'https://openrouter.example/api/v1/chat/completions').to_return do
      revoke_consent
      { status: 503, body: '{"error":{"message":"synthetic provider error: 503 upstream unavailable"}}',
        headers: { 'Content-Type' => 'application/json' } }
    end.then.to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    failure = nil
    allow(Llm::Runtime).to receive(:chat) do |**request|
      Llm::ChatRequestRunner.new(messages: request.fetch(:messages), chat: chat, account: account,
                                 model: 'openai/gpt-5.4-mini', feature: :assistant).call
    rescue StandardError => e
      failure = e
      raise
    end

    expect { described_class.perform_now(run.id) }.not_to raise_error
    expect(wire).to have_been_requested.once
    expect(run.reload.status).to eq('skipped'), "#{failure&.class}: #{failure&.backtrace&.first(3)}"
    expect(run.shadow_reply).to be_nil
  end

  it 'does not recreate erased sources or send to the judge when erasure races generation' do
    run = capture
    allow(Llm::Runtime).to receive(:chat) do
      Message.where(id: inbound.id).delete_all
      Struct.new(:content).new({ 'response' => 'Цена 20000' })
    end
    described_class.perform_now(run.id)
    expect(Captain::ShadowTraining::Run.exists?(run.id)).to be false
    expect(a_request(:post, 'http://127.0.0.1:18080/completion')).not_to have_been_made
  end

  it 'retains the generated reply during judge failure and retries only the local comparison' do
    run = capture
    stub_request(:post, 'http://127.0.0.1:18080/completion').to_timeout
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('awaiting_comparison')
    expect(run.candidates.count).to eq(0)
    stub_judge
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('completed')
    expect(Llm::Runtime).to have_received(:chat).once
  end

  it 'does not compare concurrently or repeat an uncertain generation after worker death' do
    run = capture
    run.update!(status: 'generating', phase_started_at: Time.current)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('generating')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'marks a stale unknown generation for human review without a second paid generation' do
    run = capture
    run.update!(status: 'generating', execution_token: 'old-worker', phase_started_at: 16.minutes.ago)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('interrupted_pending_review')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'recovers a stale comparison using its persisted shadow and never regenerates' do
    run = capture
    run.update!(status: 'comparing', shadow_reply: 'Цена 20000', execution_token: 'old-worker', phase_started_at: 16.minutes.ago)
    stub_judge
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('completed')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'ignores a late result from a worker whose generation lease was revoked' do
    run = capture
    allow(Llm::Runtime).to receive(:chat) do
      run.reload.update!(status: 'generating', phase_started_at: 16.minutes.ago)
      described_class.perform_now(run.id)
      Struct.new(:content).new({ 'response' => 'LATE_RESULT' })
    end
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('interrupted_pending_review')
    expect(run.shadow_reply).to be_nil
  end

  it 'records equivalence without creating knowledge or claiming action success' do
    run = capture
    stub_judge(verdict.merge('verdict' => 'equivalent', 'discrepancies' => [], 'faq_candidates' => []))
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('completed')
    expect(run.candidates.count).to eq(0)
    expect(run.snapshot['limitations']).to include('no_tool_choice_evaluation', 'operator_is_not_ground_truth')
  end

  it 'uses the canonical router in memory without a live session or human target' do
    other = create(:captain_assistant, account: account, description: 'Второй агент', routing_description: 'Другие услуги')
    assistant.update!(routing_description: 'Консультации')
    run = capture
    router = instance_double(Captain::Runtime::DecisionRouter)
    decision = Captain::Runtime::DecisionRouter::Decision.new(kind: 'agent', agent_ids: [other.id])
    expect(Captain::Runtime::DecisionRouter).to receive(:new) do |snapshot, **|
      expect(snapshot.latest_message).to include('Сколько стоит')
      expect(snapshot.to_state.to_json).not_to include('HUMAN_TARGET_ONLY')
      router
    end
    allow(router).to receive(:decide).and_return(decision)
    stub_judge
    described_class.perform_now(run.id)
    expect(run.reload.assistant_id).to eq(other.id)
    expect(run.status).to eq('completed')
  end

  it 'records a council as pending review rather than pretending to assess tool or council execution' do
    create(:captain_assistant, account: account, routing_description: 'Другие услуги')
    assistant.update!(routing_description: 'Консультации')
    run = capture
    router = instance_double(Captain::Runtime::DecisionRouter,
                             decide: Captain::Runtime::DecisionRouter::Decision.new(kind: 'council', agent_ids: [assistant.id]))
    allow(Captain::Runtime::DecisionRouter).to receive(:new).and_return(router)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('pending_routing')
    expect(run.error_code).to eq('routing_council_requires_review')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'cascades local snapshots and candidates on source deletion instead of blocking subject erasure' do
    run = capture
    candidate = run.candidates.create!(account: account, kind: 'regression', proposal: { review_required: true })
    Message.where(id: inbound.id).delete_all
    expect(Captain::ShadowTraining::Run.exists?(run.id)).to be false
    expect(Captain::ShadowTraining::Candidate.exists?(candidate.id)).to be false
  end

  it 'prevents foreign-account candidate ownership' do
    run = capture
    candidate = run.candidates.build(account: create(:account), kind: 'faq', proposal: { question: 'Q' })
    expect(candidate).not_to be_valid
  end

  it 'keeps the real outbound privacy gateway active for synthetic names, phone and IIN without target leakage' do
    inbound.update!(content: 'Меня зовут Айгерим Ахметова, телефон +77015556677, ИИН 950412400123. Сколько стоит консультация?')
    run = capture
    wire = stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions').with do |request|
      expect(request.body).not_to include('Айгерим', 'Ахметова', '+77015556677', '950412400123', 'HUMAN_TARGET_ONLY')
      expect(request.body).to include('PII_NAME_', 'PII_PHONE_', 'IIN_TOKEN_')
      true
    end.to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    context = RubyLLM.context do |config|
      config.openrouter_api_key = 'synthetic-key'
      config.openrouter_api_base = 'https://openrouter.ai/api/v1'
    end
    connection = RubyLLM::Connection.new(RubyLLM::Providers::OpenRouter.new(context.config), context.config)
    allow(Llm::Runtime).to receive(:chat) do |**request|
      connection.post('chat/completions', { model: 'synthetic-model', messages: request.fetch(:messages) })
      Struct.new(:content).new({ 'response' => 'Цена неизвестна.' })
    end

    Captain::ShadowTraining::Generator.new(run).call
    expect(wire).to have_been_requested.once
    expect(Llm::PiiSessionPseudonymizer).not_to be_active
  end
end
