# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark do
  let(:redis_url) { 'redis://127.0.0.1:6379/15' }
  let(:fixture_data) do
    {
      workspace: {
        agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                   tool_ids: [], model: 'openai/gpt-6-luna' }]
      },
      dialogues: [{ id: 'case_1', turns: [{ customer: 'Здравствуйте',
                                           expect: { agent: 'Регистратор', council: false,
                                                     forbidden: %w[false_success_claim wrong_language] } }] }]
    }
  end

  describe Captain::Evals::RoutingBenchmark::Guard do
    it 'refuses production before opening the database' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      expect(ActiveRecord::Base).not_to receive(:connection)

      expect do
        described_class.check!(redis_url: redis_url, benchmark_redis_url: redis_url)
      end.to raise_error(ArgumentError, 'Production is forbidden')
    end

    it 'refuses a database outside the isolated suffixes' do
      expect do
        described_class.check!(database_name: 'onelink_dev', redis_url: redis_url, benchmark_redis_url: redis_url)
      end.to raise_error(ArgumentError, /isolated benchmark/)
    end

    it 'requires a separate loopback Redis DB' do
      expect do
        described_class.check!(database_name: 'onelink_benchmark', redis_url: redis_url,
                               benchmark_redis_url: 'redis://127.0.0.1:6379/0')
      end.to raise_error(ArgumentError, /separate benchmark Redis/)
    end
  end

  describe Captain::Evals::RoutingBenchmark::Fixture do
    it 'accepts a tiny dialogue and rejects an unknown acting agent' do
      expect(described_class.new(fixture_data).dialogues.size).to eq(1)
      invalid = fixture_data.deep_dup
      invalid[:dialogues].first[:turns].first[:expect][:agent] = 'Другой'

      expect { described_class.new(invalid) }.to raise_error(described_class::Invalid, /unknown/)
    end

    it 'rejects a different model and a missing council expectation' do
      invalid = fixture_data.deep_dup
      invalid[:workspace][:agents].first[:model] = 'other-model'
      expect { described_class.new(invalid) }.to raise_error(described_class::Invalid, /Luna|luna/)

      invalid = fixture_data.deep_dup
      invalid[:dialogues].first[:turns].first[:expect].delete(:council)
      expect { described_class.new(invalid) }.to raise_error(described_class::Invalid, /council/)
    end

    it 'rejects an external network tool in the fixture' do
      invalid = fixture_data.deep_dup
      invalid[:workspace][:agents].first[:tool_ids] = ['web_search']

      expect { described_class.new(invalid) }.to raise_error(described_class::Invalid, /Unsupported benchmark tool/)
    end
  end

  describe Captain::Evals::RoutingBenchmark::Scorer do
    it 'scores a scripted tool response and catches an unsupported success claim' do
      account = create(:account)
      assistant = create(:captain_assistant, account: account, name: 'Регистратор')
      conversation = create(:conversation, account: account)
      scorer = described_class.new(account: account, conversation: conversation)
      turn = fixture_data.dig(:dialogues, 0, :turns, 0).deep_stringify_keys
      before = described_class::OPERATION_MODELS.keys.index_with { {} }
      response = { 'agent_id' => assistant.id, 'response' => 'Здравствуйте!', 'captain_request_id' => 'synthetic-request' }

      expect(scorer.call(turn: turn, response: response, events: [], before: before)).to include(status: 'pass')

      response['response'] = 'Готово, записал вас.'
      result = scorer.call(turn: turn, response: response, events: [], before: before)
      expect(result).to include(status: 'fail', reasons: include('false_success_claim'))
      expect(result[:hard_zero]['false_success_claim']).to eq(1)
    end
  end

  describe Captain::Evals::RoutingBenchmark::Runner do
    it 'scores a tiny fixture using scripted runtime responses without network delivery' do
      fixture = Captain::Evals::RoutingBenchmark::Fixture.new(fixture_data)
      allow(Captain::Evals::RoutingBenchmark::Guard).to receive(:check!).and_return(true)
      allow(Captain::Evals::RoutingBenchmark::Guard).to receive(:restrict_http!).and_return(true)
      allow(Dir).to receive(:glob).and_call_original
      allow(Dir).to receive(:glob).with('synthetic/*.yml').and_return(['synthetic/case.yml'])
      allow(Captain::Evals::RoutingBenchmark::Fixture).to receive(:load).and_return(fixture)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |assistant:, conversation:, **|
        # Benchmark rows are not Playground rows (the Playground boundary would block every tool); they carry
        # their own marker, and the isolated database has no webhook or provider to deliver to.
        expect(conversation.additional_attributes).to include('captain_benchmark_source' => true)
        expect(Outbound::PlaygroundDeliveryPolicy.policy_for(conversation: conversation)).to be_nil
        instance_double(Captain::Assistant::AgentRunnerService,
                        generate_response: { 'agent_id' => assistant.id, 'response' => 'Здравствуйте!',
                                             'captain_request_id' => 'synthetic-request' })
      end
      out = Rails.root.join('tmp', "synthetic-benchmark-#{SecureRandom.uuid}.json")
      runner = described_class.new(fixtures: 'synthetic/*.yml', runs: 1, budget_usd: 1, out: out)
      allow(runner).to receive(:write_report)

      report = runner.call

      expect(report.dig(:aggregates, :passed)).to eq(1)
      expect(report.dig(:cases, 0, :acting_agent)).to eq('Регистратор')
      expect(report[:cost_usd]).to eq(0)
      expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(
        hash_including(source: 'benchmark', conversation: a_kind_of(Conversation))
      )
    end
  end
end
