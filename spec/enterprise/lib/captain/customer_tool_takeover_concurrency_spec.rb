require 'rails_helper'
require 'timeout'

RSpec.describe 'Captain customer tool vs shared Thread takeover' do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Before contact') }
  let(:conversation) { create(:conversation, account: account, contact: contact, status: :pending) }
  let(:control_thread) { create(:communication_thread, account: account, contact: contact) }
  let(:task) do
    create(:crm_task, account: account, originating_conversation: conversation,
                      customer_visible: true, customer_title: 'Before task')
  end

  before do
    account.enable_features!('crm_tasks')
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    create(:communication_thread_conversation, communication_thread: control_thread,
                                               conversation: conversation, primary: true)
    conversation.association(:communication_thread).reset
    allow(Captain::ToolExecutionAuditService).to receive(:record)
  end

  def state
    @state ||= {
      account_id: account.id, assistant_id: assistant.id,
      conversation: { id: conversation.id }, contact: { id: contact.id },
      captain_response_fence: { control_generation: control_thread.reload.captain_control_generation }
    }
  end

  def tool_for(kind)
    return Captain::Tools::UpdateContactTool.new(assistant) if kind == :contact

    Captain::Tools::CustomerTasksTool.new(assistant)
  end

  def execute(kind, tool)
    context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state }))
    return tool.execute(context, name: 'After contact') if kind == :contact

    tool.execute(context, action: 'update', task_id: task.id, title: 'After task', idempotency_key: 'takeover-task')
  end

  def unchanged!(kind)
    expect(contact.reload.name).to eq('Before contact')
    expect(task.reload.customer_title).to eq('Before task') if kind == :task
  end

  def human_takeover!
    pid = ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
    Conversation.find(conversation.id).activate_captain_human_control!(source: 'agent_reply')
    expect(control_thread.reload.captain_control_state).to eq('human')
    pid
  end

  def worker_for(kind, tool)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:takeover_tool_worker] = true
        [ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i, execute(kind, tool)]
      end
    rescue StandardError => e
      e
    end
  end

  def wait_for_block!(blocked_pid, blocker_pid)
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{blocked_pid})")
        break if blockers.include?(blocker_pid.to_s)

        sleep 0.01
      end
    end
  end

  [:contact, :task].each do |kind|
    it "denies stale #{kind} after human commits between the real precheck and phone lock" do
      state
      task if kind == :task
      tool = tool_for(kind)
      entered = Queue.new
      release = Queue.new
      allow(Contacts::PhoneIdentityLock).to receive(:acquire!).and_wrap_original do |method, **kwargs|
        if Thread.current[:takeover_tool_worker]
          entered << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          Timeout.timeout(15) { release.pop }
        end
        method.call(**kwargs)
      end
      worker = worker_for(kind, tool)
      worker_pid = Timeout.timeout(20) { entered.pop }
      expect(human_takeover!).not_to eq(worker_pid)
      unchanged!(kind)
      release << true
      expect(Timeout.timeout(20) { worker.value }).to be_a(Captain::Conversation::ControlGenerationStaleError)
      unchanged!(kind)
    ensure
      release&.push(true)
      Timeout.timeout(20) { worker.value } if worker&.alive?
    end

    it "serializes #{kind} effect before human takeover when the tool holds the Thread owner" do
      state
      task if kind == :task
      tool = tool_for(kind)
      entered = Queue.new
      release = Queue.new
      started = Queue.new
      allow(tool).to receive(:ensure_tool_execution_allowed!).and_wrap_original do |method|
        method.call
        if Thread.current[:takeover_tool_worker]
          entered << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          Timeout.timeout(15) { release.pop }
        end
      end
      worker = worker_for(kind, tool)
      worker_pid = Timeout.timeout(20) { entered.pop }
      human = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          pid = ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          started << pid
          Conversation.find(conversation.id).activate_captain_human_control!(source: 'agent_reply')
        end
      rescue StandardError => e
        e
      end
      human_pid = Timeout.timeout(20) { started.pop }
      expect(human_pid).not_to eq(worker_pid)
      wait_for_block!(human_pid, worker_pid)
      expect(control_thread.reload.captain_control_state).to eq('ai')
      release << true
      result = Timeout.timeout(20) { worker.value }
      raise result if result.is_a?(StandardError)

      expect(JSON.parse(result.last)['action']).to eq(kind == :contact ? 'update_contact' : 'updated')
      human_result = Timeout.timeout(20) { human.value }
      raise human_result if human_result.is_a?(StandardError)
      expect(control_thread.reload.captain_control_state).to eq('human')
      expect { execute(kind, tool_for(kind)) }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      expect(contact.reload.name).to eq(kind == :contact ? 'After contact' : 'Before contact')
      expect(task.reload.customer_title).to eq('After task') if kind == :task
    ensure
      release&.push(true)
      [worker, human].compact.each { |running| Timeout.timeout(20) { running.value } if running.alive? }
    end
  end

  it 'fences the get_contact adapter against human control even though it bypasses BasePublicTool' do
    state
    human_takeover!
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'get_contact')
    context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state }))

    expect { adapter.execute(context, contact_id: contact.id) }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end

  it 'waits behind a direct Contact owner callback without holding the Thread row or deadlocking' do
    state
    agent = create(:user, account: account)
    owner_held = Queue.new
    release_owner = Queue.new
    tool_started = Queue.new
    allow_any_instance_of(Contacts::OwnerSyncService).to receive(:sync_communication_threads!).and_wrap_original do |method|
      if Thread.current[:takeover_owner_writer]
        owner_held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Timeout.timeout(15) { release_owner.pop }
      end
      method.call
    end
    owner_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:takeover_owner_writer] = true
        Current.user = agent
        record = Contact.find(contact.id)
        record.human_owner_assignment_requested = true
        record.update!(owner: agent)
      ensure
        Current.user = nil
      end
    rescue StandardError => e
      e
    end
    owner_pid = Timeout.timeout(20) { owner_held.pop }
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    allow(Contacts::PhoneIdentityLock).to receive(:acquire!).and_wrap_original do |method, **kwargs|
      result = method.call(**kwargs)
      tool_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i if Thread.current[:takeover_tool_worker]
      result
    end
    worker = worker_for(:contact, tool)
    worker_pid = Timeout.timeout(20) { tool_started.pop }
    wait_for_block!(worker_pid, owner_pid)
    expect(CommunicationThread.where(id: control_thread.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release_owner << true
    owner_result = Timeout.timeout(20) { owner_writer.value }
    raise owner_result if owner_result.is_a?(StandardError)
    expect(Timeout.timeout(20) { worker.value }).to be_a(Captain::Conversation::ControlGenerationStaleError)
    expect(control_thread.reload.captain_control_state).to eq('human')
    unchanged!(:contact)
  ensure
    release_owner&.push(true)
    [owner_writer, worker].compact.each { |running| Timeout.timeout(20) { running.value } if running.alive? }
  end
end
