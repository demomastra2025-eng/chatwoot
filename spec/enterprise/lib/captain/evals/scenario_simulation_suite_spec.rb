# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ScenarioSimulationSuite do
  let(:account) { create(:account) }

  it 'runs read-only live-safe scenario simulations through injected Captain adapters' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('captain_scenario_simulation.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: live.read_only_help
              description: Captain answers a read-only help request.
              tags: [scenario_simulation, read_only]
              autopilot: true
              autopilot_turns: 1
              user_simulator:
                scripted_messages:
                  - "Помогите с записью"
              expected:
                require_assistant_response_after_last_user: true
        YAML
      )

      result = described_class.new(
        account: account,
        cases_path: cases_path,
        agent_factory: ->(**_kwargs) { assistant_adapter('Могу помочь с записью. Уточните дату и услугу.') },
        user_client: nil,
        judge_client: nil,
        cache_store: nil
      ).call

      expect(result.to_h).to include(
        suite_id: 'captain.scenario_simulation',
        total_count: 1,
        passed_count: 1,
        status: 'pass'
      )
      expect(result.cases.first).to include(id: 'live.read_only_help', status: 'pass')
      expect(result.cases.first[:artifact]).to include(
        case_id: 'live.read_only_help',
        status: 'pass',
        timeline: include(include(type: 'message', role: 'assistant'))
      )
    end
  end

  it 'blocks mutating live scenario cases unless the case explicitly opts in' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('captain_scenario_simulation.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: live.unsafe_mutation
              description: Mutation cases must not run accidentally.
              tags: [scenario_simulation, mutating_tool]
              autopilot: true
              user_simulator:
                scripted_messages:
                  - "Поменяй сумму сделки"
              expected:
                require_assistant_response_after_last_user: true
        YAML
      )

      result = described_class.new(
        account: account,
        cases_path: cases_path,
        agent_factory: ->(**_kwargs) { assistant_adapter('Готово.') },
        user_client: nil,
        judge_client: nil,
        cache_store: nil
      ).call

      expect(result.to_h).to include(total_count: 1, error_count: 1, status: 'fail')
      expect(result.cases.first).to include(id: 'live.unsafe_mutation', status: 'error')
      expect(result.cases.first.dig(:actual, :error)).to include('unsafe_live_scenario_requires_allow_mutations')
    end
  end

  def assistant_adapter(content)
    Class.new(Llm::Evals::Scenario::AgentAdapter) do
      define_method(:initialize) { super(role: :agent, name: 'SpecCaptain') }
      define_method(:call) do |_input|
        { messages: [{ role: 'assistant', content: content }] }
      end
    end.new
  end
end
