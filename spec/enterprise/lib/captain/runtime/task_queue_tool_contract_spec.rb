# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::TaskQueueTool do
  subject(:tool) { described_class.new }

  let(:context) do
    {
      state: { assistant_id: 91, private_provider_body: 'synthetic-private-body' },
      agent_graph: [{ id: 91 }, { id: 92 }],
      agent_request_id: 'synthetic-request',
      private_tool_results: { record: 'synthetic-private-record' }
    }
  end
  let(:run_context) { Captain::Runtime::RunContext.new(context) }
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }
  let(:requested_tasks) do
    [{ title: 'Prepare quote', assistant_id: 91 }, { title: 'Move appointment', assistant_id: 92 }]
  end

  def create_queue
    JSON.parse(tool.execute(tool_context, action: 'create', tasks: requested_tasks))
  end

  def update_task(**attributes)
    tool.execute(tool_context, action: 'update', **attributes)
  end

  it 'returns shared tasks and identifies the current actor and its own task IDs after create' do
    payload = create_queue
    own_task, peer_task = context[:agent_tasks]

    expect(payload.keys).to contain_exactly('tasks', 'current_agent_id', 'own_tasks', 'own_task_ids')
    expect(payload['tasks']).to eq(context[:agent_tasks])
    expect(payload['current_agent_id']).to eq(91)
    expect(payload['own_tasks']).to eq([own_task])
    expect(payload['own_task_ids']).to eq([own_task['id']])
    expect(payload['tasks'].pluck('status')).to eq(%w[active awaiting])
    expect(payload['own_task_ids']).not_to include(peer_task['id'])
    expect(payload.to_json).not_to include('synthetic-private-body', 'synthetic-private-record')
  end

  it 'updates and resumes the same own task without changing the peer task or creating new IDs' do
    create_queue
    own_id = context[:agent_tasks].first['id']
    peer_before = context[:agent_tasks].last.deep_dup
    ids_before = context[:agent_tasks].pluck('id')
    waiting = JSON.parse(update_task(task_id: own_id, status: 'waiting', result: 'Customer will provide amount'))
    resumed = JSON.parse(update_task(task_id: own_id, status: 'active'))

    expect(waiting['own_tasks'].first).to include('id' => own_id, 'status' => 'waiting', 'result' => 'Customer will provide amount')
    expect(resumed['own_tasks'].first).to include('id' => own_id, 'status' => 'active')
    expect(resumed['own_task_ids']).to eq([own_id])
    expect(resumed['tasks'].pluck('id')).to eq(ids_before)
    expect(context[:agent_tasks].last).to eq(peer_before)
    expect(resumed['current_agent_id']).to eq(91)
  end

  it 'retains completed own results for identification without authorizing their repeated execution' do
    create_queue
    own_id = context[:agent_tasks].first['id']
    completed = JSON.parse(update_task(task_id: own_id, status: 'completed', result: 'Quote prepared from verified facts'))
    before = context.deep_dup
    failure = update_task(task_id: own_id, status: 'active')

    expect(completed['own_tasks'].first).to include('status' => 'completed', 'result' => 'Quote prepared from verified facts')
    expect(completed['own_task_ids']).to eq([own_id])
    expect(failure).to include(success: false, retryable: false)
    expect(failure.dig(:data, :code)).to eq('task_finished')
    expect(context).to eq(before)
  end

  [['waiting', 'task_not_owned'], ['completed', 'task_finished']].each do |peer_status, code|
    it "rejects acknowledging a peer's #{peer_status} task without mutating the queue" do
      create_queue
      peer = context[:agent_tasks].last
      peer['status'] = peer_status
      before = context.deep_dup

      failure = update_task(task_id: peer['id'], status: peer_status, result: 'Acknowledged peer task')

      expect(failure).to include(success: false, retryable: false)
      expect(failure.dig(:data, :code)).to eq(code)
      expect(failure.dig(:data, :current_agent_id)).to eq(91)
      expect(failure.dig(:data, :own_task_ids)).to eq([context[:agent_tasks].first['id']])
      expect(failure.dig(:data, :own_task_ids)).not_to include(peer['id'])
      expect(context).to eq(before)
      expect(failure.to_json).not_to include('synthetic-private-body', 'synthetic-private-record')
    end
  end

  it 'returns a specific correction and existing own IDs when update omits task_id' do
    create_queue
    before = context.deep_dup

    failure = update_task(status: 'waiting', result: 'Customer will provide amount')

    expect(failure).to include(success: false, retryable: false)
    expect(failure.dig(:data, :code)).to eq('task_id_required')
    expect(failure[:error]).to include('task_id', 'own_task_ids')
    expect(failure.dig(:data, :own_task_ids)).to eq([context[:agent_tasks].first['id']])
    expect(failure.dig(:audit, :failure_reason)).to eq('task_id_required')
    expect(context).to eq(before)
  end

  it 'does not create an empty queue when update has no task ID and no plan exists' do
    before = context.deep_dup

    failure = update_task(status: 'completed')

    expect(failure.dig(:data, :code)).to eq('task_id_required')
    expect(failure.dig(:data, :own_task_ids)).to eq([])
    expect(context).to eq(before)
    expect(context).not_to have_key(:agent_tasks)
  end

  it 'rejects an invented task ID and returns only known own IDs' do
    create_queue
    before = context.deep_dup

    failure = update_task(task_id: 'unknown-task', status: 'completed')

    expect(failure.dig(:data, :code)).to eq('task_not_found')
    expect(failure.dig(:data, :own_task_ids)).to eq([context[:agent_tasks].first['id']])
    expect(context).to eq(before)
  end

  it 'derives task ownership from the current RunContext after a handoff' do
    create_queue
    first_id, target_id = context[:agent_tasks].pluck('id')
    context[:state][:assistant_id] = 92
    Captain::Runtime::TaskQueue.new(run_context.context).on_handoff

    payload = JSON.parse(update_task(task_id: target_id, status: 'waiting', result: 'Customer clarification needed'))

    expect(payload['current_agent_id']).to eq(92)
    expect(payload['own_task_ids']).to eq([target_id])
    expect(payload['own_tasks']).to eq([context[:agent_tasks].last])
    expect(payload['own_task_ids']).not_to include(first_id)
    expect(payload['tasks'].pluck('status')).to eq(%w[awaiting waiting])
    expect(payload['tasks'].pluck('id')).to eq([first_id, target_id])
  end

  it 'preserves the existing explicit cancellation of another agent\'s unfinished request' do
    create_queue
    own_id, peer_id = context[:agent_tasks].pluck('id')

    payload = JSON.parse(update_task(task_id: peer_id, status: 'cancelled', result: 'Customer withdrew this request'))

    expect(payload['tasks'].last).to include('id' => peer_id, 'status' => 'cancelled', 'result' => 'Customer withdrew this request')
    expect(payload['own_task_ids']).to eq([own_id])
    expect(payload['own_tasks']).to eq([context[:agent_tasks].first])
    expect(payload['current_agent_id']).to eq(91)
  end

  it 'does not echo invalid supplied values or private context in a typed failure' do
    failure = tool.execute(
      tool_context, action: 'create',
      tasks: [{ title: 'Prepare quote', assistant_id: 'synthetic-private-input' }, requested_tasks.last]
    )

    expect(failure).to include(success: false, retryable: false)
    expect(failure.dig(:data, :code)).to eq('invalid_task_request')
    expect(failure[:data].keys).to contain_exactly(:code, :current_agent_id, :own_task_ids)
    expect(failure.to_json).not_to include('synthetic-private-input', 'synthetic-private-body', 'synthetic-private-record')
    expect(context[:agent_tasks]).to be_empty
  end
end
