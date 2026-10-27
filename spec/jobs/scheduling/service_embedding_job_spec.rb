require 'rails_helper'

# A burst of saves of the services of one account queues ONE delayed job; a save that leaves the embedded text as it is queues none.
RSpec.describe Scheduling::ServiceEmbeddingJob do
  let(:account) { create(:account) }

  before { Redis::Alfred.delete(described_class.queued_key(account.id)) }

  describe '.enqueue' do
    it 'queues one job, delayed, and lets later calls join it' do
      freeze_time do
        expect { expect(described_class.enqueue(account.id)).to be(true) }
          .to have_enqueued_job(described_class).with(account.id).at(30.seconds.from_now)

        expect { expect(described_class.enqueue(account.id)).to be(false) }.not_to have_enqueued_job(described_class)
      end
    end

    it 'queues a job of another account on its own' do
      other = create(:account)
      Redis::Alfred.delete(described_class.queued_key(other.id))
      described_class.enqueue(account.id)

      expect { described_class.enqueue(other.id) }.to have_enqueued_job(described_class).with(other.id)
    end

    it 'can run at once' do
      expect { described_class.enqueue(account.id, wait: 0) }.to have_enqueued_job(described_class).with(account.id)
    end

    it 'gives the claim back when the job cannot be queued' do
      allow(described_class).to receive(:set).and_raise(RuntimeError, 'redis is down')

      expect { described_class.enqueue(account.id) }.to raise_error(RuntimeError, 'redis is down')
      expect(Redis::Alfred.exists?(described_class.queued_key(account.id))).to be(false)
    end
  end

  describe '#perform' do
    it 'refreshes the stale services of the account and lets the next save queue a new job' do
      described_class.enqueue(account.id)
      allow(Scheduling::ServiceIndex).to receive(:refresh!).with(account.id).and_return(3)

      described_class.perform_now(account.id)

      expect(Scheduling::ServiceIndex).to have_received(:refresh!).with(account.id)
      expect(Redis::Alfred.exists?(described_class.queued_key(account.id))).to be(false)
    end

    it 'does not fail, and does not retry, when embeddings are not configured' do
      allow(Scheduling::ServiceIndex).to receive(:refresh!).and_raise(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError, 'no key')

      expect { described_class.perform_now(account.id) }.not_to raise_error
    end

    it 'fails, to be retried, when the embedding model fails' do
      allow(Scheduling::ServiceIndex).to receive(:refresh!).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'HTTP 502')

      expect { described_class.perform_now(account.id) }.to raise_error(Captain::Llm::EmbeddingService::EmbeddingsError, 'HTTP 502')
    end
  end
end
