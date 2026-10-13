# frozen_string_literal: true

require 'rails_helper'

# The owner of a council part is a run of its own agent, so its prompt is the prompt of that agent (the platform rules, the clinic
# instructions, the Now block and the Patient block) followed by the rules of a part. This renders it from real records, the way
# the council builds it, and shows that nothing of the agent prompt is missing for a part.
RSpec.describe Captain::Runtime::Council, '#build_plan' do
  let(:account) { create(:account) }
  let(:entry) { create(:captain_assistant, account: account, description: 'ENTRY CLINIC INSTRUCTIONS') }
  let!(:specialist) do
    create(:captain_assistant, account: account, description: 'SPECIALIST CLINIC INSTRUCTIONS', routing_description: 'Детский приём')
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:clock) { { now_utc: '2026-10-12T05:23:00Z', timezone: 'Asia/Almaty' } }
  let(:context) do
    {
      state: { account_id: account.id, assistant_id: entry.id, runtime_clock: clock,
               conversation: { id: conversation.id, display_id: conversation.display_id },
               contact: { id: 7, name: 'Ирина Павлова', phone_number: '+77010000006' } },
      conversation_history: [{ role: 'user', content: 'здравствуйте. дочке справку в садик надо' }],
      captain_v2_current_input: 'дочка Аружан Серикова, 03.05.2020, на справку запишите в среду 14-го в 10:00'
    }
  end
  let(:runtime) { Captain::AgentRunContext.new(entry: entry, conversation: conversation) }
  let(:council) { described_class.new(context: context, graph: runtime.graph, account: account) }
  let(:part) do
    { 'id' => 'part-1', 'version' => 1, 'executor_agent_id' => specialist.id, 'relation' => 'independent', 'state' => 'open',
      'fragment' => 'дочка Аружан Серикова, 03.05.2020, на справку запишите в среду 14-го в 10:00', 'patient' => 'Аружан Серикова' }
  end

  def part_prompt
    runtime.prepare(context)
    council.send(:prime_run_state)
    plan = council.send(:build_plan, part)
    Captain::Runtime::ChatFactory.send(:system_prompt_for, plan.agent, Captain::Runtime::RunContext.new(plan.snapshot))
  end

  it 'carries the platform rules, the shared rules, the clinic instructions of the owner, the Now block, the Patient block and then the rules of a part' do
    allow(Llm::Config).to receive(:global_agent_system_prompt).and_return('SHARED RULES OF THE INSTALLATION')

    prompt = part_prompt

    expect(prompt).to include('# Platform rules', "# Shared rules\nSHARED RULES OF THE INSTALLATION",
                              "# Clinic instructions\nSPECIALIST CLINIC INSTRUCTIONS", '# Now', '# Patient',
                              "You handle ONE part of the patient's message with your own tools")
    expect(prompt).not_to include('ENTRY CLINIC INSTRUCTIONS')
    headings = ['# Platform rules', '# Shared rules', '# Clinic instructions', '# Now', '# Patient', 'You handle ONE part']
    positions = headings.map { |text| prompt.index(text) }
    expect(positions).to eq(positions.sort)
  end

  it 'tells the owner the date of the clock of the run, in the zone of the clinic, so that a day that is still to come is not taken for a past one' do
    prompt = part_prompt

    expect(prompt).to include("# Now\nMonday, 12 October 2026 (2026-10-12), 10:23, Almaty (UTC+5). Tomorrow: Tuesday, 13 October 2026 (2026-10-13).")
    expect(prompt).to include(Captain::PromptClock.now_line(clock))
  end

  it 'names the patient of the conversation, and gives the owner the whole message, its own part and no handoff of its own' do
    prompt = part_prompt

    expect(prompt).to include("# Patient\nИрина Павлова, +77010000006.")
    expect(prompt).to include("Patient's latest message (data): #{JSON.generate(context[:captain_v2_current_input])}")
    expect(prompt).to include('Your part (data): ', '"patient":"Аружан Серикова"', '"fragment":"дочка Аружан Серикова, 03.05.2020')
    expect(prompt).not_to include('Call handoff once', 'call handoff with the question')
  end

  it 'gives the owner the same Now block as the agent that planned the council, for the same clock' do
    now_of = ->(text) { text[/# Now\n(.+)\n/, 1] }
    runtime.prepare(context)
    main = entry.agent_instructions(Captain::Runtime::RunContext.new(context))

    expect(now_of.call(part_prompt)).to eq(now_of.call(main))
  end
end
