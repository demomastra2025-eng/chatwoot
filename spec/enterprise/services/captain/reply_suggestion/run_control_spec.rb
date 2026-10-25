require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::RunControl do
  let(:request_id) { SecureRandom.uuid }
  let(:far_deadline) { Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600 }

  describe '.checkpoint!' do
    it 'does nothing outside a reply suggestion run (a live conversation is not affected)' do
      expect(Captain::ReplySuggestion::RequestStore).not_to receive(:cancel_requested?)

      expect { described_class.checkpoint!(:turn) }.not_to raise_error
    end

    it 'lets a run go on while it is neither cancelled nor out of time' do
      described_class.with(request_id: request_id, deadline: far_deadline) do
        expect { described_class.checkpoint!(:turn) }.not_to raise_error
      end
    end

    it 'stops a cancelled run with the stage it was stopped at' do
      Captain::ReplySuggestion::RequestStore.request_cancel!(request_id)

      described_class.with(request_id: request_id, deadline: far_deadline) do
        expect { described_class.checkpoint!(:tool) }.to raise_error(Captain::ReplySuggestion::RunAborted) { |error|
          expect([error.kind, error.stage]).to eq([:cancelled, 'tool'])
        }
      end
    end

    it 'stops a run that is out of time without asking Redis' do
      expect(Captain::ReplySuggestion::RequestStore).not_to receive(:cancel_requested?)

      described_class.with(request_id: request_id, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1) do
        expect { described_class.checkpoint!(:turn) }.to raise_error(Captain::ReplySuggestion::RunAborted) { |error|
          expect([error.kind, error.stage]).to eq([:deadline, 'turn'])
        }
      end
    end

    it 'asks Redis for the cancel flag at most every 0.3 s' do
      allow(Captain::ReplySuggestion::RequestStore).to receive(:cancel_requested?).and_return(false)

      described_class.with(request_id: request_id, deadline: far_deadline) do
        10.times { described_class.checkpoint!(:turn) }
      end

      expect(Captain::ReplySuggestion::RequestStore).to have_received(:cancel_requested?).once
    end

    it 'notices a cancel that comes later, once the interval has passed' do
      allow(Captain::ReplySuggestion::RequestStore).to receive(:cancel_requested?).and_return(false, true)

      described_class.with(request_id: request_id, deadline: far_deadline) do
        described_class.checkpoint!(:turn)
        sleep Captain::ReplySuggestion::CANCEL_CHECK_INTERVAL + 0.05
        expect { described_class.checkpoint!(:turn) }.to raise_error(Captain::ReplySuggestion::RunAborted)
      end
    end

    it 'is a no-op again after the run, and restores the control of an outer run' do
      described_class.with(request_id: 'outer', deadline: far_deadline) do
        described_class.with(request_id: request_id, deadline: far_deadline) { nil }
        expect(described_class.current.request_id).to eq('outer')
      end

      expect(described_class.current).to be_nil
    end
  end

  describe 'another thread of the same run' do
    it 'gets the control of the run (its cancel, its deadline and its cards) and gives it back afterwards' do
      Captain::ReplySuggestion::RequestStore.request_cancel!(request_id)
      seen = nil

      described_class.with(request_id: request_id, deadline: far_deadline) do |control|
        Thread.new do
          described_class.adopt(control) do
            described_class.register_action('card-of-a-part')
            seen = begin
              described_class.checkpoint!(:tool)
            rescue Captain::ReplySuggestion::RunAborted => e
              e.kind
            end
          end
          expect(described_class.current).to be_nil
        end.join

        expect(control.action_ids).to eq(['card-of-a-part'])
      end

      expect(seen).to eq(:cancelled)
    end
  end

  describe 'the cards of a run' do
    it 'collects the approval cards the run prepared' do
      described_class.with(request_id: request_id, deadline: far_deadline) do |control|
        described_class.register_action('a-1')
        described_class.register_action('a-1')
        described_class.register_action('a-2')

        expect(control.action_ids).to eq(%w[a-1 a-2])
      end
    end

    it 'ignores a card outside a run' do
      expect { described_class.register_action('a-1') }.not_to raise_error
    end
  end

  describe Captain::ReplySuggestion::RunAborted do
    it 'is a stale-generation error, so that the runtime re-raises it at every layer' do
      expect(described_class.ancestors).to include(Captain::Conversation::ControlGenerationStaleError)
    end
  end
end
