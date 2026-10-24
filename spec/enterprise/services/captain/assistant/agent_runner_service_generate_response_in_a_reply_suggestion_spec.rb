# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant::AgentRunnerService, '#generate_response in a reply suggestion' do
  let(:service) { described_class.new(assistant: assistant, conversation: conversation, source: source, request_id: request_id) }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account)) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:source) { 'reply_suggestion' }
  let(:request_id) { SecureRandom.uuid }
  let(:message_history) { [{ role: 'user', content: 'Спасибо!' }] }
  let(:mock_runner) { instance_double(Captain::Runtime::AgentRunner) }
  let(:runner_output) do
    { 'patient_language' => 'Russian', 'response' => '', 'response_mode' => 'suppress', 'operator_note' => 'Только благодарность.' }
  end
  let(:runner_result) { instance_double(Captain::Runtime::Result, output: runner_output, context: { current_agent: 'assistant_agent' }, error: nil) }

  before do
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    allow(Captain::Runtime::Runner).to receive(:with_agents).and_return(mock_runner)
    allow(mock_runner).to receive(:run).and_return(runner_result)
    Captain::Runtime::CallbackManager::EVENT_TYPES.each { |event_type| allow(mock_runner).to receive(:"on_#{event_type}").and_return(mock_runner) }
  end

  describe 'the way the agent says that nobody should write' do
    it 'keeps the note for the operator of a suppressed reply' do
      expect(service.generate_response(message_history: message_history))
        .to include('response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => 'Только благодарность.')
    end

    context 'when a staff member must answer' do
      let(:runner_output) { { 'response' => 'Выдумка', 'response_mode' => 'human', 'operator_note' => 'В базе нет ответа, решает врач.' } }

      it 'answers without a text, flagged for a human, with the note of the agent' do
        result = service.generate_response(message_history: message_history)

        expect(result).to include('response' => '', 'response_mode' => 'human', 'response_human_needed' => true,
                                  'operator_note' => 'В базе нет ответа, решает врач.')
      end

      context 'when the run is a live conversation' do
        let(:source) { 'incoming_message' }

        it 'does not accept it: a live agent hands over through the handoff tool' do
          result = service.generate_response(message_history: message_history)

          expect(result).not_to include('response_human_needed')
          expect(result['error_class']).to eq('Captain::Assistant::AgentRunnerService::SemanticOutputError')
        end
      end
    end
  end

  describe 'the id of the run' do
    it 'is the id of the request when the caller has one, so that every llm event of the run shares it' do
      expect(service.generate_response(message_history: message_history)['captain_request_id']).to eq(request_id)
    end

    it 'is a new id otherwise' do
      anonymous = described_class.new(assistant: assistant, conversation: conversation, source: source)

      expect(anonymous.generate_response(message_history: message_history)['captain_request_id']).to match(/\A\h{8}(-\h{4}){3}-\h{12}\z/)
    end
  end

  describe 'a stop of the run' do
    let(:far_deadline) { Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600 }

    it 'is not turned into a result of the run' do
      allow(mock_runner).to receive(:run).and_raise(Captain::ReplySuggestion::RunAborted.new(:cancelled, 'turn'))

      expect { service.generate_response(message_history: message_history) }.to raise_error(Captain::ReplySuggestion::RunAborted)
    end

    it 'is not swallowed by the retry of a failed finalization either' do
      allow(service).to receive(:finalization_only_retry_eligible?).and_return(true)
      allow(service).to receive(:run_finalization_only_retry).and_raise(Captain::ReplySuggestion::RunAborted.new(:deadline, 'turn'))

      expect { service.send(:finalization_only_retry_response, StandardError.new('x'), {}) }
        .to raise_error(Captain::ReplySuggestion::RunAborted)
    end

    it 'ends a cancelled run before the agent is called' do
      Captain::ReplySuggestion::RequestStore.request_cancel!(request_id)

      Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: far_deadline) do
        expect { service.generate_response(message_history: message_history) }
          .to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect(error.stage).to eq('moderation') }
      end

      expect(mock_runner).not_to have_received(:run)
    end
  end
end
