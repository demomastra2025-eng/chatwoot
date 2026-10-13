require 'rails_helper'
require 'timeout'

# A council part is a normal run of the agent that owns it, so these examples stub the run of a part (Council::PartRun, which has
# its own spec) and check what the council does around it: which parts run where, how an outcome is recorded and what the
# customer reads.
RSpec.describe Captain::Runtime::Council do
  # Sentences the runtime used to write to the patient itself (ru). The council writes none: the reply holds the owners' texts only.
  let(:stock_sentences) do
    ['На этот вопрос я сейчас не могу ответить.', 'По этому вопросу вам ответит сотрудник клиники.', 'Действие выполнено.',
     'Запрос отменён.', 'Не начато: предыдущий шаг не завершён.', 'Запрос отправлен, подтверждение придёт сообщением.']
  end
  let(:booked) { 'Вы записаны к терапевту Иванову на 14 октября в 10:00.' }
  let(:editor) { instance_double(Captain::Runtime::CouncilEditor) }
  let(:runs) { [] }
  let(:results) { {} }
  let(:actors) { { 1 => actor(1, writer: true), 2 => actor(2, writer: false), 3 => actor(3, writer: true) } }
  let(:graph) do
    instance_double(Captain::AgentGraph, entry: actors[1], inbox: nil, agents: actors.values).tap do |item|
      allow(item).to receive(:find) { |id| actors[id] }
    end
  end
  let(:context) do
    { parts: [], state: { assistant_id: 1, conversation: { id: 7 }, captain_response_fence: { last_message_id: 5, routing_revision: 2 } },
      captain_v2_current_input: 'Запишите меня к терапевту на 14 октября и сколько стоит МРТ',
      agent_graph: [{ id: 1, name: 'Администратор', description: 'Запись' }, { id: 2, name: 'Прайс', description: 'Цены' },
                    { id: 3, name: 'Лаборатория', description: 'Анализы' }],
      conversation_history: [{ role: 'user', content: 'Здравствуйте' }, { role: 'assistant', content: '{"response":"Добрый день!"}' }] }
  end
  let(:council) { described_class.new(context: context, graph: graph, account: nil, llm_context: :llm_context) }

  def actor(id, writer:)
    tool = if writer
             double("write tool #{id}", name: 'create_appointment', metadata: { risk_level: 'high', idempotent: false })
           else
             double("read tool #{id}", name: 'faq_lookup', metadata: { read_only: true, risk_level: 'low' })
           end
    runtime = Captain::Runtime::Agent.new(name: "assistant_#{id}", instructions: 'Owner', tools: [tool])
    double("actor #{id}", id: id, name: "Агент #{id}", agent_name: "assistant_#{id}", config: {}, prompt_context_state: {}, agent: runtime,
                          avatar_url: nil, handoff_enabled?: true, selected_agent_tool_ids: %w[faq_lookup handoff],
                          resolved_agent_model: 'openai/gpt-6-luna')
  end

  # The registry parts of a request: the part with the index n belongs to the agent n + 1 (1 and 3 write, 2 only reads).
  def parts(patients = %w[Анна Анна], owners: nil)
    patients.each_with_index.map do |patient, index|
      { 'id' => "part-#{index}", 'version' => 1, 'executor_agent_id' => (owners || [1, 2, 3])[index], 'fragment' => "Запрос #{index}",
        'patient' => patient, 'relation' => 'independent', 'state' => 'open', 'delivered' => [] }
    end.tap { |items| context[:parts] = items.deep_dup }
  end

  # What the run of a part returns (see Council::PartRun): the structured answer and what the tools did.
  def ran(text = '', status: 'answered', sources: ['faq_lookup'], questions: [], acted: false, pending: false, technical: nil, suggested: '',
          summary: '', tracking: {})
    output = { 'status' => status, 'customer_text' => text, 'questions' => questions, 'sources' => sources, 'suggested_agent' => suggested,
               'reasoning' => '' }
    { output: output, acted: acted, pending: pending, technical: technical, summary: summary, duration_ms: 12, tracking: tracking,
      mutations_succeeded: acted ? 1 : 0, mutations_failed: 0, mutations_unknown: 0, tools_called: 2, turns: 3 }
  end

  def unparsable(acted: false)
    ran.merge(output: nil, acted: acted)
  end

  def technical_failure(tool: 'create_appointment')
    { 'tool' => tool, 'kind' => 'technical', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable', 'mutating' => true }
  end

  def edited(reply = 'Единое сообщение.')
    allow(editor).to receive(:edit) do |**kwargs|
      editor_calls << kwargs
      Captain::Runtime::CouncilEditor::Outcome.new(reply: reply)
    end
  end

  let(:editor_calls) { [] }

  before do
    allow(Captain::AssistantSafetyPreferences).to receive(:for).and_return({})
    allow(Captain::Runtime::CouncilEditor).to receive(:new).and_return(editor)
    allow(editor).to receive(:edit).and_return(Captain::Runtime::CouncilEditor::Outcome.new(reply: nil, reason: 'timeout'))
    allow(council).to receive(:fresh_actor) { |id| actors[id] }
    allow(Captain::Runtime::CoordinationEvents).to receive(:council_started)
    allow(Captain::Runtime::CoordinationEvents).to receive(:council_finished)
    allow(Captain::Runtime::CoordinationEvents).to receive(:council_edited)
    allow(Captain::Runtime::CoordinationEvents).to receive(:council_editor_fallback)
    allow(Captain::Runtime::CoordinationEvents).to receive(:part_started)
    allow(Captain::Runtime::CoordinationEvents).to receive(:part_finished)
    allow(Captain::Runtime::Council::PartRun).to receive(:new) do |agent:, snapshot:, **|
      part_id = snapshot[:active_part_id]
      tracker = double('tracker', acted?: false, summary: '')
      double("run of #{part_id}", tracker: tracker).tap do |part_run|
        allow(part_run).to receive(:call) do |fragment|
          runs << { id: part_id, fragment: fragment, thread: Thread.current, snapshot: snapshot, agent: agent,
                    executed_by: Current.executed_by, owner_in_registry: context[:parts].find { |part| part['id'] == part_id }&.dig('executor_agent_id'),
                    scope: { policy: Current.playground_run_policy, account: Current.account, locale: I18n.locale, zone: Time.zone.name } }
          result = results.fetch(part_id)
          result.respond_to?(:call) ? result.call : result
        end
      end
    end
  end

  after { Current.reset }

  def run_council(items)
    council.run(items)
  end

  def state_of(part_id)
    context[:parts].find { |part| part['id'] == part_id }
  end

  describe 'a part that acts' do
    it 'is a run of its owner with its own tools: the owner books at once and its text states what the tools returned' do
      items = parts
      results.merge!('part-0' => ran(booked, acted: true, sources: ['create_appointment'], summary: 'create_appointment: ok'),
                     'part-1' => ran('МРТ стоит 15000 тенге.'))
      edited('Вы записаны на 14 октября в 10:00. МРТ стоит 15000 тенге.')

      reply = run_council(items)

      expect(reply).to eq('Вы записаны на 14 октября в 10:00. МРТ стоит 15000 тенге.')
      expect(editor_calls.sole[:parts]).to eq([{ 'text' => booked, 'done' => true, 'staff_will_answer' => false },
                                               { 'text' => 'МРТ стоит 15000 тенге.', 'done' => false, 'staff_will_answer' => false }])
      expect(state_of('part-0')).to include('state' => 'done', 'acted' => true, 'summary' => booked)
      expect(state_of('part-1')).to include('state' => 'answered', 'acted' => false)
      expect(context).not_to have_key(:council_handoff)
      expect(defined?(Captain::Runtime::ConfirmedOperations)).to be_nil
    end

    it 'sends the text of a council of one part as it is and does not call the editor' do
      items = parts(%w[Анна], owners: [1])
      results['part-0'] = ran(booked, acted: true, sources: ['create_appointment'])

      expect(run_council(items)).to eq(booked)
      expect(editor).not_to have_received(:edit)
      expect(state_of('part-0')['state']).to eq('done')
    end

    it 'runs the owner with the tools of its agent minus the control tools, the structured result and no handoff target' do
      run_council(parts(%w[Анна], owners: [1]).tap { results['part-0'] = ran(booked, acted: true) })

      agent = runs.sole[:agent]
      expect(agent.name).to eq('assistant_1')
      expect(agent.tools.map(&:name)).to eq(['create_appointment'])
      expect(agent.response_schema).to eq(Captain::Runtime::PartSchema)
      expect(agent.handoff_agents).to be_empty
      expect(agent.context_preparer).to be_nil
      expect(runs.sole[:fragment]).to eq('Запрос 0')
    end

    it 'gives the part its own context: the owner, the part scope, the full message of the customer and no state of the main run' do
      context[:agent_tasks] = [{ 'id' => 't', 'status' => 'active' }]
      context[:agent_run_context_object] = Object.new
      context[:captain_v2_tool_result_cache] = { 'x' => 1 }
      context[:captain_v2_bound_tool_ids] = ['plan_request']
      context[:pending_human_handoff] = { reason: 'x' }
      items = parts
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('МРТ стоит 15000 тенге.'))
      run_council(items)

      writer = runs.find { |run| run[:id] == 'part-0' }[:snapshot]
      reader = runs.find { |run| run[:id] == 'part-1' }[:snapshot]
      expect(writer).to include(part_run: true, part_plan_accepted: true, active_part_id: 'part-0', active_part_version: 1,
                                current_agent: 'assistant_1', part_language: 'ru', part_staff_handoff: true,
                                part_customer_message: 'Запишите меня к терапевту на 14 октября и сколько стоит МРТ')
      expect(writer[:state]).to include(assistant_id: 1)
      expect(writer[:state][:captain_response_fence]).to include(last_message_id: 5, part_id: 'part-0', part_version: 1)
      expect(writer[:state][:captain_response_fence]).not_to have_key(:routing_revision)
      expect(writer[:part_info]).to include(id: 'part-0', patient: 'Анна', fragment: 'Запрос 0')
      expect(writer[:part_peers]).to eq([{ name: 'Прайс', description: 'Цены' }, { name: 'Лаборатория', description: 'Анализы' }])
      expect(writer[:conversation_history]).to eq([{ role: 'user', content: 'Здравствуйте' }, { role: 'assistant', content: 'Добрый день!' }])
      %i[agent_graph agent_graph_object agent_run_context_object agent_tasks parts captain_v2_tool_result_cache captain_v2_bound_tool_ids
         pending_human_handoff].each { |key| expect(writer).not_to have_key(key) }
      expect(reader[:state]).to include(assistant_id: 2)
      expect(reader[:active_part_id]).to eq('part-1')
    end

    it 'gives a run without a fence (a Playground run) no fence either: a fence of part ids alone would look for a conversation' do
      context[:state].delete(:captain_response_fence)
      results['part-0'] = ran(booked, acted: true)

      run_council(parts(%w[Анна], owners: [1]))

      expect(runs.sole[:snapshot][:state]).not_to have_key(:captain_response_fence)
    end

    it 'gives only a writer the durable session, so that its actions are protected from being repeated' do
      session = Captain::Conversation::AgentSession.new(entry: create(:captain_assistant))
      context[:agent_session] = session
      items = parts
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('МРТ стоит 15000 тенге.'))
      allow(Captain::Runtime::PartRegistry).to receive(:new).and_return(instance_double(Captain::Runtime::PartRegistry, record_result!: nil))

      run_council(items)

      expect(runs.find { |run| run[:id] == 'part-0' }[:snapshot][:agent_session]).to be(session)
      expect(runs.find { |run| run[:id] == 'part-1' }[:snapshot]).not_to have_key(:agent_session)
    end

    it 'shows a Playground session to the part as its owner, so that the owner passes the checks of the session' do
      session = double('playground session')
      view = double('playground view')
      allow(session).to receive(:acting_as).with(2).and_return(view)
      context[:playground_session] = session
      results['part-0'] = ran('Цена 5000.')

      run_council(parts(%w[Анна], owners: [2]))

      expect(runs.sole[:snapshot][:playground_session]).to be(view)
    end

    it 'restores the actor of the job after every part' do
      previous = Object.new
      Current.executed_by = previous
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(runs.pluck(:executed_by)).to contain_exactly(actors[1], actors[2])
      expect(Current.executed_by).to be(previous)
    end
  end

  describe 'what the owner is told about an earlier version of its part' do
    def continued(prior)
      items = parts(%w[Анна], owners: [2])
      items.first.merge!({ 'version' => 2, 'link_action' => 'answer', 'prior_questions' => ['Какой врач?'] }.merge(prior))
      results['part-0'] = ran('Готово.')
      run_council(items)
      runs.sole[:snapshot][:part_info]
    end

    it 'hands on what the earlier version concluded, with its questions' do
      info = continued('prior_summary' => 'На какое время вас записать?', 'prior_state' => 'waiting_customer', 'prior_acted' => false)

      expect(info).to include(prior_summary: 'На какое время вас записать?', questions: ['Какой врач?'])
    end

    it 'does not hand on the summary of an earlier version that ended unresolved: it concluded nothing, so the owner looks again' do
      info = continued('prior_summary' => 'Не нашла такой услуги.', 'prior_state' => 'unknown', 'prior_acted' => false)

      expect(info).not_to have_key(:prior_summary)
      expect(info).to include(questions: ['Какой врач?'], link_action: 'answer')
    end

    it 'keeps the summary of an unresolved earlier version that had acted: what it did is a fact' do
      info = continued('prior_summary' => 'Запись на 10:00 создана.', 'prior_state' => 'unknown', 'prior_acted' => true)

      expect(info).to include(prior_summary: 'Запись на 10:00 создана.', prior_acted: true)
    end

    it 'reads a part stored before the state of the earlier version was kept as it was' do
      info = continued('prior_summary' => 'Старый итог.')

      expect(info).to include(prior_summary: 'Старый итог.')
    end
  end

  describe 'where the parts run' do
    it 'runs every mutating part on the calling thread and a read-only part on a thread of its own' do
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(runs.find { |run| run[:id] == 'part-0' }[:thread]).to be(Thread.current)
      expect(runs.find { |run| run[:id] == 'part-1' }[:thread]).not_to be(Thread.current)
      expect(Captain::Runtime::CoordinationEvents).to have_received(:part_started).with(hash_including(lane: 'writer', inline: true))
      expect(Captain::Runtime::CoordinationEvents).to have_received(:part_started).with(hash_including(lane: 'reader', inline: false))
    end

    it 'gives the thread of a read-only part the scope of the calling thread: the delivery policy of a Playground run, the locale, the zone' do
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))
      policy = { 'token' => 'synthetic-playground-token' }
      account = create(:account)
      Current.playground_run_policy = policy
      Current.account = account

      I18n.with_locale(:kk) { Time.use_zone('Asia/Almaty') { run_council(parts) } }

      writer = runs.find { |run| run[:id] == 'part-0' }
      reader = runs.find { |run| run[:id] == 'part-1' }
      expect(reader[:thread]).not_to be(Thread.current)
      expect(reader[:scope]).to eq(policy: policy, account: account, locale: :kk, zone: 'Asia/Almaty')
      expect(reader[:scope]).to eq(writer[:scope])
    end

    it 'does not hand the thread the policy of the calling thread by reference: the part cannot change it' do
      policy = { 'token' => 'synthetic-playground-token' }
      Current.playground_run_policy = policy
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => lambda {
        Current.playground_run_policy['token'] = 'changed'
        ran('Цена')
      })

      run_council(parts)

      expect(runs.find { |run| run[:id] == 'part-1' }[:thread]).not_to be(Thread.current)
      expect(Current.playground_run_policy).to eq('token' => 'synthetic-playground-token')
    end

    it 'starts the read-only parts side by side with the writer lane' do
      started = Queue.new
      release = Queue.new
      results.merge!('part-0' => lambda {
        started << :writer
        release.pop
        ran(booked, acted: true)
      }, 'part-1' => lambda {
        started << :reader
        release.pop
        ran('Цена')
      })
      worker = Thread.new { run_council(parts) }

      seen = Array.new(2) { Timeout.timeout(5) { started.pop } }
      expect(seen).to contain_exactly(:writer, :reader)
      2.times { release << true }
      expect(worker.value).to be_present
    ensure
      2.times { release << true } if release
      worker&.join(1)
    end

    it 'runs the parts of mutating owners one after another in plan order, also for different people' do
      order = []
      results.merge!('part-0' => lambda {
        order << :first_start
        sleep 0.05
        order << :first_end
        ran(booked, acted: true)
      }, 'part-1' => lambda {
        order << :second_start
        ran('Борис записан на 15 октября в 11:00.', acted: true)
      })

      run_council(parts(%w[Анна Борис], owners: [1, 3]))

      expect(order).to eq(%i[first_start first_end second_start])
      expect(runs.pluck(:thread).uniq).to eq([Thread.current])
    end

    it 'runs a read-only dependent part in the lane of its prerequisite, after it' do
      order = []
      items = parts(%w[Анна Анна])
      items.last.merge!('relation' => 'conditional', 'depends_on_part_id' => 'part-0')
      context[:parts] = items.deep_dup
      results.merge!('part-0' => lambda {
        order << :prerequisite
        ran(booked, acted: true)
      }, 'part-1' => lambda {
        order << :dependent
        ran('Цена')
      })

      run_council(items)

      expect(order).to eq(%i[prerequisite dependent])
      expect(runs.pluck(:thread).uniq).to eq([Thread.current])
    end

    it 'runs everything on the calling thread, in plan order, when the threads are switched off' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('CAPTAIN_COUNCIL_PARALLEL', nil).and_return('off')
      results.merge!('part-0' => ran('Цена'), 'part-1' => ran('Адрес'), 'part-2' => ran(booked, acted: true))

      run_council(parts(%w[Анна Анна Анна], owners: [2, 2, 1]))

      expect(runs.pluck(:id)).to eq(%w[part-0 part-1 part-2])
      expect(runs.pluck(:thread).uniq).to eq([Thread.current])
    end

    it 'runs a lane on the calling thread when no slot for a thread is free' do
      allow(described_class::SLOTS).to receive(:try_acquire).and_return(false)
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(runs.pluck(:thread).uniq).to eq([Thread.current])
    end

    it 'gives the slot back when the lane is done' do
      free = described_class::SLOTS.available_permits
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(described_class::SLOTS.available_permits).to eq(free)
    end

    it 'is switched off by the environment or an installation setting, and on otherwise' do
      expect(described_class.parallel?).to be(true)
      %w[off 0 false disabled no].each do |value|
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('CAPTAIN_COUNCIL_PARALLEL', nil).and_return(value)
        expect(described_class.parallel?).to be(false)
      end
    end
  end

  describe 'the outcome of a part' do
    it 'keeps the question of the owner, waits for the customer and promises no staff' do
      question = 'На какой день вам удобно?'
      results['part-0'] = ran(question, status: 'needs_information', questions: [question], sources: [])

      reply = run_council(parts(%w[Анна], owners: [1]))

      expect(reply).to eq(question)
      expect(state_of('part-0')).to include('state' => 'waiting_customer', 'missing_fields' => [question])
      expect(context).not_to have_key(:council_handoff)
    end

    it 'asks the listed questions itself when the owner wrote no text' do
      results['part-0'] = ran('', status: 'needs_information', questions: ['На какой день вам удобно?'], sources: [])

      expect(run_council(parts(%w[Анна], owners: [1]))).to eq('На какой день вам удобно?')
    end

    it 'reports an action and then asks for what is missing: waiting for the customer, and still done' do
      text = "#{booked} Нужен ли вам талон на анализы?"
      results['part-0'] = ran(text, status: 'needs_information', questions: ['Нужен ли вам талон на анализы?'], acted: true)
      results['part-1'] = ran('Цена')
      edited

      run_council(parts)

      expect(state_of('part-0')).to include('state' => 'waiting_customer', 'acted' => true)
      expect(editor_calls.sole[:parts].first).to include('text' => text, 'done' => true)
    end

    it 'does not pass on an answer that has no source and acted on nothing: the part is unknown, nothing is sent and staff answer it' do
      results['part-0'] = ran('Приём стоит 5000 тенге.', sources: [])

      reply = run_council(parts(%w[Анна], owners: [2]))

      expect(reply).to eq('')
      expect(state_of('part-0')['state']).to eq('unknown')
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
      expect(context).not_to have_key(:council_note)
    end

    it 'sends nothing and hands nothing over when the agent cannot hand off, and leaves a private note that nobody answers the part' do
      allow(actors[1]).to receive(:handoff_enabled?).and_return(false)
      results['part-0'] = ran('', status: 'unavailable', sources: [])

      expect(run_council(parts(%w[Анна], owners: [2]))).to eq('')
      expect(context).not_to have_key(:council_handoff)
      expect(context[:council_note]).to eq(unanswered: ['Запрос 0'])
    end

    it 'keeps the honest sentence of an owner that cannot resolve its part and hands the part to staff after the reply' do
      sentence = 'Результаты анализов вам сообщит сотрудник клиники.'
      results.merge!('part-0' => ran('Цена'), 'part-1' => ran(sentence, status: 'unavailable', sources: []))
      edited

      run_council(parts)

      expect(editor_calls.sole[:parts]).to eq([{ 'text' => 'Цена', 'done' => false, 'staff_will_answer' => false },
                                               { 'text' => sentence, 'done' => false, 'staff_will_answer' => true }])
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 1'])
      expect(state_of('part-1')['state']).to eq('unknown')
    end

    it 'marks the part that the conversation goes to staff for as handed to staff, and no other part' do
      results.merge!('part-0' => ran('Цена'), 'part-1' => ran('', status: 'unavailable', sources: []))
      edited

      run_council(parts)

      expect(state_of('part-1')).to include('handed_to_staff' => true)
      expect(state_of('part-0')).not_to have_key('handed_to_staff')
    end

    it 'marks a part that failed technically too, because the failure hands the conversation to staff' do
      results.merge!('part-0' => ran('Цена'), 'part-1' => ran('', technical: technical_failure))
      edited

      run_council(parts)

      expect(state_of('part-1')).to include('handed_to_staff' => true)
    end

    it 'marks nothing when the conversation cannot go to staff: nobody took the part over' do
      allow(actors[1]).to receive(:handoff_enabled?).and_return(false)
      results['part-0'] = ran('', status: 'unavailable', sources: [])

      run_council(parts(%w[Анна], owners: [2]))

      expect(state_of('part-0')).not_to have_key('handed_to_staff')
    end

    it 'counts an action as done also when the owner returned no usable answer, writes no sentence for it and notes it for staff' do
      results['part-0'] = unparsable(acted: true)

      expect(run_council(parts(%w[Анна], owners: [1]))).to eq('')
      expect(state_of('part-0')).to include('state' => 'done', 'acted' => true, 'reply_text' => '')
      expect(context).not_to have_key(:council_handoff)
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])
    end

    it 'leaves a part without a usable answer and without an action unknown, for staff, and sends nothing' do
      results['part-0'] = unparsable

      expect(run_council(parts(%w[Анна], owners: [2]))).to eq('')
      expect(state_of('part-0')['state']).to eq('unknown')
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
    end

    it 'counts a write that waits for the confirmation of the provider as done and sends the text of its owner, not one of its own' do
      sentence = 'Запрос на запись отправлен, подтверждение придёт сообщением.'
      results['part-0'] = ran(sentence, acted: true, pending: true)

      expect(run_council(parts(%w[Анна], owners: [1]))).to eq(sentence)
      expect(state_of('part-0')).to include('state' => 'done', 'reply_text' => sentence)
      expect(context).not_to have_key(:council_handoff)
      expect(context).not_to have_key(:council_note)
    end

    it 'writes no sentence for a pending write whose owner wrote no text, and notes it for staff' do
      results['part-0'] = ran('', acted: true, pending: true)

      expect(run_council(parts(%w[Анна], owners: [1]))).to eq('')
      expect(state_of('part-0')['state']).to eq('done')
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])
    end

    it 'keeps the action of a part as the summary when it ended without a text of its own' do
      results['part-0'] = unparsable(acted: true).merge(summary: 'create_appointment: {"appointment_id":7}')

      run_council(parts(%w[Анна], owners: [1]))

      expect(state_of('part-0')['summary']).to eq('create_appointment: {"appointment_id":7}')
    end

    [true, false].each do |staff|
      it "writes no line of its own for a part without any text, in Kazakh too, when staff #{staff ? 'can' : 'cannot'} take it over" do
        allow(actors[1]).to receive(:handoff_enabled?).and_return(staff)
        context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'
        results['part-0'] = ran('', status: 'unavailable', sources: [])

        expect(run_council(parts(%w[Анна], owners: [2]))).to eq('')
      end
    end

    it 'leaves a part without any text out of the lines for the editor and out of the contributors' do
      results.merge!('part-0' => ran('', status: 'unavailable', sources: []), 'part-1' => ran('Цена'), 'part-2' => ran('Адрес'))
      edited

      run_council(parts(%w[Анна Анна Анна], owners: [2, 2, 3]))

      expect(editor_calls.sole[:parts]).to eq([{ 'text' => 'Цена', 'done' => false, 'staff_will_answer' => false },
                                               { 'text' => 'Адрес', 'done' => false, 'staff_will_answer' => false }])
      expect(editor_calls.sole[:parts].to_json).not_to include(*stock_sentences)
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
      expect(context[:council_untold_part_ids]).to eq(['part-0'])
    end

    it 'sends nothing when no part has a text, and hands every unresolved part to staff once, without the editor' do
      results.merge!('part-0' => ran('', status: 'unavailable', sources: []), 'part-1' => ran('', status: 'unavailable', sources: []))

      expect(run_council(parts)).to eq('')
      expect(editor).not_to have_received(:edit)
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0', 'Запрос 1'])
      expect(context[:council_untold_part_ids]).to eq(%w[part-0 part-1])
    end

    it 'has no key left for a sentence the runtime used to write to the patient' do
      %w[cancelled action_pending action_not_started action_done part_staff_will_answer part_cannot_answer].each do |key|
        %i[ru kk en].each { |locale| expect(I18n.exists?("captain.coordination.#{key}", locale)).to be(false) }
      end
    end

    it 'keeps only the private notes for staff in the coordination texts, in every language' do
      %i[ru kk en].each do |locale|
        keys = I18n.t('captain.coordination', locale: locale).keys
        expect(keys).to contain_exactly(:unresolved_handoff, :technical_failure_note, :unreported_action_note)
      end
    end

    it 'sends the part texts in order when the editor produces nothing, and drops a question that repeats for the same person' do
      question = 'На какую дату?'
      results.merge!('part-0' => ran(question, status: 'needs_information', questions: [question]),
                     'part-1' => ran(question, status: 'needs_information', questions: [question]))

      expect(run_council(parts(%w[Анна анна]))).to eq(question)
      expect(editor).to have_received(:edit)
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_editor_fallback).with(hash_including(reason: 'timeout'))
    end

    it 'keeps the same question for different people' do
      question = 'На какую дату?'
      results.merge!('part-0' => ran(question, status: 'needs_information', questions: [question]),
                     'part-1' => ran(question, status: 'needs_information', questions: [question]))

      expect(run_council(parts(%w[Анна Борис]))).to eq("#{question}\n\n#{question}")
    end

    it 'reports the reply of the editor and its language' do
      context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'
      results.merge!('part-0' => ran('Баға 5000 теңге.'), 'part-1' => ran('Мекенжай: Абай, 1.'))
      edited('Баға 5000 теңге, мекенжай: Абай, 1.')

      expect(run_council(parts(%w[Анна Борис], owners: [2, 2]))).to eq('Баға 5000 теңге, мекенжай: Абай, 1.')
      expect(editor_calls.sole).to include(language: 'kk')
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_edited).with(hash_including(language: 'kk', handoff: false))
    end

    it 'sends the part texts in order when the editor itself fails' do
      allow(editor).to receive(:edit).and_raise(StandardError, 'boom')
      results.merge!('part-0' => ran('Приём стоит 5000 тенге.'), 'part-1' => ran('Адрес: улица Абая, 1.'))

      expect(run_council(parts(%w[Анна Борис], owners: [2, 2]))).to eq("Приём стоит 5000 тенге.\n\nАдрес: улица Абая, 1.")
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_editor_fallback).with(hash_including(reason: 'error'))
    end

    it 'edits with the model of the acting agent unless the runner passes its own' do
      results.merge!('part-0' => ran('Баға'), 'part-1' => ran('Мекенжай'))

      run_council(parts(%w[Анна Борис], owners: [2, 2]))
      expect(Captain::Runtime::CouncilEditor).to have_received(:new).with(
        context: context, account: nil, llm_context: :llm_context, model: 'openai/gpt-6-luna'
      )

      runner_model = described_class.new(context: context, graph: graph, account: nil, model: 'openai/gpt-6-sol')
      allow(runner_model).to receive(:fresh_actor) { |id| actors[id] }
      runner_model.run(parts(%w[Анна Борис], owners: [2, 2]))
      expect(Captain::Runtime::CouncilEditor).to have_received(:new).with(hash_including(model: 'openai/gpt-6-sol'))
    end
  end

  describe 'a part that is not for its owner' do
    let(:named_agents) do
      [double('first', id: 1, name: 'Администратор'), double('second', id: 2, name: 'Прайс'), double('third', id: 3, name: 'Лаборатория')]
    end

    before { allow(graph).to receive(:agents).and_return(named_agents) }

    def out_of_scope(name)
      ran('', status: 'out_of_scope', sources: [], suggested: name)
    end

    it 'is run again, once, by the agent the owner names, which is stored before the new owner runs' do
      sequence = [out_of_scope(' «лаборатория» '), ran('Анализы готовы через два дня.')]
      results['part-0'] = -> { sequence.shift }

      reply = run_council(parts(%w[Анна], owners: [1]))

      expect(reply).to eq('Анализы готовы через два дня.')
      expect(runs.pluck(:owner_in_registry)).to eq([1, 3])
      expect(runs.pluck(:executed_by)).to eq([actors[1], actors[3]])
      expect(state_of('part-0')).to include('executor_agent_id' => 3, 'state' => 'answered')
      expect(context[:council_contributors].pluck(:id)).to eq([1, 3])
    end

    it 'is never reassigned twice' do
      results['part-0'] = -> { out_of_scope('Лаборатория') }

      run_council(parts(%w[Анна], owners: [1]))

      expect(runs.size).to eq(2)
    end

    it 'names the agent as listed, by name: an unknown name or a number reassigns nothing' do
      expect(council.send(:suggested_agent, ' «Лаборатория» ')&.id).to eq(3)
      expect(council.send(:suggested_agent, 'Регистратура')).to be_nil
      expect(council.send(:suggested_agent, '2')).to be_nil
      expect(council.send(:suggested_agent, '')).to be_nil
    end

    %w[Регистратура Администратор].each do |name|
      it "reassigns nothing for #{name}, which is unknown or the owner itself" do
        results['part-0'] = out_of_scope(name)

        run_council(parts(%w[Анна], owners: [1]))

        expect(runs.size).to eq(1)
      end
    end

    it 'reassigns nothing when two agents share the suggested name' do
      allow(graph).to receive(:agents).and_return(named_agents + [double('twin', id: 4, name: ' лаборатория ')])
      results['part-0'] = out_of_scope('Лаборатория')

      run_council(parts(%w[Анна], owners: [1]))

      expect(runs.size).to eq(1)
    end

    it 'does not reassign after an action: the action stays with the agent that did it' do
      results['part-0'] = ran('Записал.', status: 'out_of_scope', acted: true, suggested: 'Лаборатория')

      run_council(parts(%w[Анна], owners: [1]))

      expect(runs.size).to eq(1)
      expect(state_of('part-0')['executor_agent_id']).to eq(1)
    end
  end

  describe 'parts that depend on each other' do
    def dependent(relation)
      items = parts(%w[Анна Анна], owners: [1, 3])
      items.last.merge!('relation' => relation, 'depends_on_part_id' => 'part-0')
      context[:parts] = items.deep_dup
      items
    end

    it 'does not start a part that depends on a part which did not finish: it stays open, is not mentioned and promises no staff' do
      results['part-0'] = ran('На какой день?', status: 'needs_information', questions: ['На какой день?'])

      reply = run_council(dependent('depends_on'))

      expect(runs.pluck(:id)).to eq(['part-0'])
      expect(reply).to eq('На какой день?')
      expect(state_of('part-1')['state']).to eq('open')
      expect(context).not_to have_key(:council_handoff)
    end

    it 'leaves a dependent part out of the lines for the editor too, so that the reply holds only what was answered' do
      items = dependent('depends_on')
      items << { 'id' => 'part-2', 'version' => 1, 'executor_agent_id' => 2, 'fragment' => 'Запрос 2', 'patient' => 'Анна',
                 'relation' => 'independent', 'state' => 'open', 'delivered' => [] }
      context[:parts] = items.deep_dup
      results.merge!('part-0' => ran('На какой день?', status: 'needs_information', questions: ['На какой день?']), 'part-2' => ran('Цена'))
      edited

      run_council(items)

      expect(editor_calls.sole[:parts].pluck('text')).to eq(['На какой день?', 'Цена'])
      expect(editor_calls.sole[:parts].to_json).not_to include(*stock_sentences)
    end

    it 'does not show or mention a dependent part whose prerequisite failed technically, and hands it over with the failure' do
      items = dependent('depends_on')
      items << { 'id' => 'part-2', 'version' => 1, 'executor_agent_id' => 2, 'fragment' => 'Запрос 2', 'patient' => 'Анна',
                 'relation' => 'independent', 'state' => 'open', 'delivered' => [] }
      context[:parts] = items.deep_dup
      results.merge!('part-0' => ran('', technical: technical_failure, sources: []), 'part-2' => ran('Цена 15000 тенге.'))

      reply = run_council(items)

      expect(runs.pluck(:id)).to contain_exactly('part-0', 'part-2')
      expect(reply).to eq('Цена 15000 тенге.')
      stock_sentences.each { |sentence| expect(reply).not_to include(sentence) }
      expect(state_of('part-1')['state']).to eq('open')
      expect(context[:council_handoff]).to include(reason: 'council_technical_failure', technical: true,
                                                   failures: [technical_failure, technical_failure])
      expect(context[:council_contributors].pluck(:id)).to eq([2])
    end

    it 'ends the run as a technical failure, with no word to the customer, when only a dependent part is left after the failure' do
      items = dependent('depends_on')
      results['part-0'] = ran('', technical: technical_failure, sources: [])

      reply = run_council(items)

      expect(reply).to eq('')
      expect(context[:technical_failure]).to include('tool' => 'create_appointment', 'parts' => 2)
    end

    it 'passes the failure on along a chain of dependent parts' do
      items = parts(%w[Анна Анна Анна], owners: [1, 3, 1])
      items[1].merge!('relation' => 'depends_on', 'depends_on_part_id' => 'part-0')
      items[2].merge!('relation' => 'depends_on', 'depends_on_part_id' => 'part-1')
      context[:parts] = items.deep_dup
      results['part-0'] = ran('', technical: technical_failure, sources: [])

      expect(run_council(items)).to eq('')
      expect(context[:technical_failure]).to include('parts' => 3)
      expect(runs.pluck(:id)).to eq(['part-0'])
    end

    it 'sends nothing, and hands nothing to staff, when only a part is left that did not start: the part it waits for is of an earlier message' do
      items = parts(%w[Анна], owners: [3])
      items.first.merge!('relation' => 'depends_on', 'depends_on_part_id' => 'earlier-part')
      context[:parts] = items.deep_dup + [{ 'id' => 'earlier-part', 'version' => 1, 'state' => 'waiting_customer', 'executor_agent_id' => 1 }]

      reply = run_council(items)

      expect(reply).to eq('')
      expect(runs).to be_empty
      expect(state_of('part-0')['state']).to eq('open')
      expect(context).not_to have_key(:council_handoff)
      expect(context).not_to have_key(:council_note)
      expect(context).not_to have_key(:technical_failure)
    end

    it 'starts it when the part it depends on is done, and shows its owner how that part ended' do
      results.merge!('part-0' => ran('Визит отменён.', acted: true), 'part-1' => ran(booked, acted: true))

      run_council(dependent('depends_on'))

      expect(runs.pluck(:id)).to eq(%w[part-0 part-1])
      expect(runs.last[:snapshot][:part_prior]).to eq([{ text: 'Визит отменён.', status: 'answered', acted: true }])
    end

    it 'always starts a conditional part after the part before it, which its owner reads and decides on' do
      results.merge!('part-0' => ran('Пятница занята.', status: 'unavailable', sources: []), 'part-1' => ran(booked, acted: true))

      run_council(dependent('conditional'))

      expect(runs.pluck(:id)).to eq(%w[part-0 part-1])
      expect(runs.last[:snapshot][:part_prior]).to eq([{ text: 'Пятница занята.', status: 'unavailable', acted: false }])
    end
  end

  describe 'a run that turns stale' do
    let(:stale) { Captain::Conversation::ControlGenerationStaleError.new('newer message') }

    it 'stops, starts no later part and raises the error after every thread was joined' do
      done = Queue.new
      reader_running = Queue.new
      results.merge!('part-0' => lambda {
        Timeout.timeout(5) { reader_running.pop }
        raise stale
      }, 'part-1' => lambda {
        reader_running << :started
        sleep 0.05
        done << :reader_finished
        ran('Цена')
      }, 'part-2' => ran(booked, acted: true))

      expect { run_council(parts(%w[Анна Анна Анна], owners: [1, 2, 3])) }.to raise_error(stale)

      expect(runs.pluck(:id)).not_to include('part-2')
      expect(done.size).to eq(1)
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_finished).with(hash_including(outcome: 'unavailable'))
    end

    it 'raises the error of a thread after the writer lane finished' do
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => -> { raise stale })

      expect { run_council(parts) }.to raise_error(stale)

      expect(state_of('part-0')).to include('state' => 'done', 'acted' => true)
    end

    it 'keeps the write of a part that was interrupted: the booking happened, so the part is done' do
      tracker = double('tracker', acted?: true, summary: 'create_appointment: {"appointment_id":7}')
      part_run = double('run of part-0', tracker: tracker)
      allow(part_run).to receive(:call).and_raise(stale)
      allow(Captain::Runtime::Council::PartRun).to receive(:new).and_return(part_run)

      expect { run_council(parts(%w[Анна], owners: [1])) }.to raise_error(stale)

      expect(state_of('part-0')).to include('state' => 'done', 'acted' => true, 'summary' => 'create_appointment: {"appointment_id":7}')
    end

    it 'keeps every write that was recorded before the error' do
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => -> { raise stale })

      expect { run_council(parts(%w[Анна Борис], owners: [1, 3])) }.to raise_error(stale)

      expect(state_of('part-0')).to include('state' => 'done', 'acted' => true)
    end
  end

  describe 'a technical failure of a part' do
    it 'is not mentioned: the other parts are answered, and staff take over after the reply with the configured notice' do
      results.merge!('part-0' => ran('', technical: technical_failure, sources: []), 'part-1' => ran('Цена 15000 тенге.'))

      reply = run_council(parts)

      expect(reply).to eq('Цена 15000 тенге.')
      expect(editor).not_to have_received(:edit)
      expect(state_of('part-0')['state']).to eq('unknown')
      expect(context[:council_handoff]).to eq(reason: 'council_technical_failure', parts: [], technical: true, failures: [technical_failure])
      expect(context[:council_contributors].pluck(:id)).to eq([2])
    end

    it 'never puts a word about the failure into the reply or the lines for the editor' do
      results.merge!('part-0' => ran('', technical: technical_failure, sources: []), 'part-1' => ran('Цена'), 'part-2' => ran('Адрес'))
      edited

      run_council(parts(%w[Анна Анна Анна], owners: [1, 2, 2]))

      expect(editor_calls.sole[:parts].pluck('text')).to eq(%w[Цена Адрес])
      expect(editor_calls.sole[:parts].to_json).not_to include('provider', 'ошибк', 'не получилось')
    end

    it 'treats an internal error of a part as a technical failure of that part only, whether it ran on the calling thread or on another' do
      [[1, 2], [2, 3]].each do |owners|
        council_for_owners = described_class.new(context: context, graph: graph, account: nil)
        allow(council_for_owners).to receive(:fresh_actor) { |id| actors[id] }
        results.replace('part-0' => -> { raise 'boom' }, 'part-1' => ran('Цена'))
        context.delete(:council_handoff)

        reply = council_for_owners.run(parts(%w[Анна Анна], owners: owners))

        expect(reply).to eq('Цена')
        expect(context[:council_handoff]).to include(
          reason: 'council_technical_failure', technical: true,
          failures: [include('kind' => 'technical', 'reason' => 'council_error', 'error_class' => 'RuntimeError')]
        )
        expect(state_of('part-0')['state']).to eq('unknown')
      end
    end

    it 'ends the whole run as a technical failure when every part failed: no reply at all' do
      results.merge!('part-0' => ran('', technical: technical_failure, sources: []),
                     'part-1' => ran('', technical: technical_failure(tool: 'faq_lookup'), sources: []))

      reply = run_council(parts)

      expect(reply).to eq('')
      expect(context[:technical_failure]).to include('tool' => 'create_appointment', 'parts' => 2)
      expect(context).not_to have_key(:council_handoff)
    end

    it 'writes no sentence for an action that was already performed before the failure: it hands over to staff and notes the action' do
      results.merge!('part-0' => ran('', technical: technical_failure, acted: true, sources: []), 'part-1' => ran('Цена'))

      reply = run_council(parts)

      expect(reply).to eq('Цена')
      expect(editor).not_to have_received(:edit)
      expect(context[:council_handoff]).to include(reason: 'council_technical_failure', technical: true)
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])
      expect(state_of('part-0')).to include('state' => 'done', 'acted' => true, 'reply_text' => '')
      expect(context[:council_contributors].pluck(:id)).to eq([2])
    end

    it 'also hands a part to staff when its owner cannot hand off: it is the system that does it' do
      allow(actors[1]).to receive(:handoff_enabled?).and_return(false)
      results.merge!('part-0' => ran('', technical: technical_failure, sources: []), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(context[:council_handoff]).to include(technical: true)
    end

    it 'does not run again for a part that was settled by an earlier attempt of the request' do
      items = parts
      items.first.merge!('state' => 'done', 'acted' => true, 'summary' => 'create_appointment: {"appointment_id":7}', 'reply_text' => booked)
      context[:parts] = items.deep_dup
      results['part-1'] = ran('Цена')
      edited

      run_council(items)

      expect(runs.pluck(:id)).to eq(['part-1'])
      expect(editor_calls.sole[:parts].first).to eq('text' => booked, 'done' => true, 'staff_will_answer' => false)
    end
  end

  describe 'replaying settled parts' do
    it 'writes no sentence for a cancelled part: nothing is sent when nothing else is left' do
      items = parts(%w[Анна], owners: [1])
      items.first.merge!('state' => 'done', 'cancelled' => true)
      context[:parts] = items.deep_dup

      expect(run_council(items)).to eq('')
      expect(runs).to be_empty
      expect(context).not_to have_key(:council_handoff)
      expect(context).not_to have_key(:council_note)
    end

    it 'leaves a cancelled part out of the reply when another part is answered' do
      items = parts(%w[Анна Анна], owners: [1, 2])
      items.first.merge!('state' => 'done', 'cancelled' => true)
      context[:parts] = items.deep_dup
      results['part-1'] = ran('Цена 15000 тенге.')

      expect(run_council(items)).to eq('Цена 15000 тенге.')
      expect(runs.pluck(:id)).to eq(['part-1'])
      expect(editor).not_to have_received(:edit)
    end

    def retry_run(items)
      retried = described_class.new(context: context, graph: graph, account: nil)
      allow(retried).to receive(:fresh_actor) { |id| actors[id] }
      runs.clear
      context.delete(:council_handoff)
      retried.run(items)
    end

    it 'replays only the sentence that was sent for a part that acted and wrote no text: none, and never the results of its tools' do
      dump = 'create_appointment: {"success":true,"appointment_id":7}'
      results['part-0'] = unparsable(acted: true).merge(summary: dump)
      items = parts(%w[Анна], owners: [1])

      first = run_council(items)
      expect(state_of('part-0')).to include('summary' => dump, 'reply_text' => '')
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])

      replay = retry_run(items)

      expect(first).to eq('')
      expect(replay).to eq('')
      expect(runs).to be_empty
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])
    end

    it 'sends no sentence for a stored part that acted and has no stored sentence (an older record, an interrupted run), and notes it' do
      items = parts(%w[Анна], owners: [1])
      items.first.merge!('state' => 'done', 'acted' => true, 'summary' => 'create_appointment: {"appointment_id":7}')
      context[:parts] = items.deep_dup

      expect(run_council(items)).to eq('')
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])
    end

    it 'replays the stored sentence of a part that acted and wrote one' do
      items = parts(%w[Анна], owners: [1])
      results['part-0'] = ran(booked, acted: true, sources: ['create_appointment'], summary: 'create_appointment: ok')

      first = run_council(items)
      replay = retry_run(items)

      expect([first, replay]).to eq([booked, booked])
      expect(runs).to be_empty
      expect(context).not_to have_key(:council_note)
    end

    it 'replays a part that waits for the customer with the question it asked' do
      question = 'На какой день вам удобно?'
      results['part-0'] = ran(question, status: 'needs_information', questions: [question], sources: [])
      items = parts(%w[Анна], owners: [1])
      run_council(items)

      expect(retry_run(items)).to eq(question)
      expect(runs).to be_empty
    end

    it 'hands a part that failed technically to staff again when the job is retried, and still does not mention it' do
      items = parts
      results.merge!('part-0' => ran('', technical: technical_failure, sources: []), 'part-1' => ran('Цена'))
      first = run_council(items)
      expect(state_of('part-0')).to include('state' => 'unknown', 'technical' => technical_failure)

      replay = retry_run(items)

      expect(first).to eq('Цена')
      expect(replay).to eq('Цена')
      expect(runs).to be_empty
      expect(context[:council_handoff]).to include(reason: 'council_technical_failure', technical: true, failures: [technical_failure])
    end

    it 'treats a part that acted before its technical failure the same way when the job is retried: no sentence, a handoff and a note' do
      items = parts
      results.merge!('part-0' => ran('', technical: technical_failure, acted: true, sources: []), 'part-1' => ran('Цена'))
      run_council(items)

      replay = retry_run(items)

      expect(replay).to eq('Цена')
      expect(editor).not_to have_received(:edit)
      expect(context[:council_handoff]).to include(technical: true)
      expect(context[:council_note]).to eq(unreported: ['Запрос 0'])
    end

    it 'hands a settled part that stayed unknown to staff again, and sends nothing' do
      items = parts(%w[Анна], owners: [1])
      items.first.merge!('state' => 'unknown')
      context[:parts] = items.deep_dup

      expect(run_council(items)).to eq('')
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
      expect(runs).to be_empty
    end
  end

  describe 'what the main run learns' do
    it 'receives the names, results, actions and artifacts of the tools of the parts, without the appointment evidence' do
      tracking = { completed_tool_names: ['create_appointment'], completed_actions: ['create_appointment'], artifact_ids: ['doc-1'],
                   completed_tool_results: [{ tool_name: 'create_appointment', success: true }] }
      results['part-0'] = ran(booked, acted: true, tracking: tracking)
      context[:captain_v2_completed_tool_names] = ['faq_lookup']

      run_council(parts(%w[Анна], owners: [1]))

      expect(context[:captain_v2_completed_tool_names]).to eq(%w[faq_lookup create_appointment])
      expect(context[:captain_v2_completed_actions]).to eq(['create_appointment'])
      expect(context[:captain_v2_artifact_ids]).to eq(['doc-1'])
      expect(context[:captain_v2_completed_tool_results]).to eq([{ tool_name: 'create_appointment', success: true }])
    end

    it 'receives them also when the council raised' do
      results.merge!('part-0' => ran(booked, acted: true, tracking: { completed_tool_names: ['create_appointment'] }),
                     'part-1' => -> { raise Captain::Conversation::ControlGenerationStaleError, 'x' })

      expect { run_council(parts(%w[Анна Борис], owners: [1, 3])) }.to raise_error(Captain::Conversation::ControlGenerationStaleError)

      expect(context[:captain_v2_completed_tool_names]).to eq(['create_appointment'])
    end
  end

  describe 'events' do
    it 'publishes the start and the end of every part with identifiers, states and counts only' do
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(Captain::Runtime::CoordinationEvents).to have_received(:part_started).twice
      expect(Captain::Runtime::CoordinationEvents).to have_received(:part_finished).with(
        context: context, part: hash_including('id' => 'part-0'), state: 'done', status: 'answered', acted: true, mutations_succeeded: 1,
        mutations_failed: 0, mutations_unknown: 0, tools_called: 2, turns: 3, duration_ms: 12
      )
    end

    it 'logs the end of a part without any text' do
      allow(Rails.logger).to receive(:info)
      results['part-0'] = ran(booked, acted: true)

      run_council(parts(%w[Анна], owners: [1]))

      expect(Rails.logger).to have_received(:info).with(/\[CAPTAIN\]\[Council\] part_finished part_id=part-0 version=1 executor_agent_id=1 state=done/)
      expect(Rails.logger).not_to have_received(:info).with(/#{Regexp.escape(booked)}/)
    end
  end

  describe 'the contributors and the participants' do
    it 'names the agents that wrote a part of the reply' do
      results.merge!('part-0' => ran(booked, acted: true), 'part-1' => ran('Цена'))

      run_council(parts)

      expect(context[:council_contributors]).to eq([{ id: 1, name: 'Агент 1', avatar_url: nil }, { id: 2, name: 'Агент 2', avatar_url: nil }])
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_started).with(
        context: context, participant_ids: [1, 2], part_ids: %w[part-0 part-1]
      )
    end
  end
end
