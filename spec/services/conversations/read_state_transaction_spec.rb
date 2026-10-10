require 'rails_helper'

RSpec.describe Conversations::ReadStateTransaction do
  let(:conversation) { create(:conversation, agent_last_seen_at: 20.minutes.ago).reload }

  def database_deadlock!
    ActiveRecord::Base.connection.execute(<<~SQL)
      DO $$ BEGIN
        RAISE EXCEPTION 'Injected read-state deadlock' USING ERRCODE = '40P01';
      END $$;
    SQL
  end

  it 'rolls back each failed attempt before retrying within an existing transaction' do
    original_cursor = conversation.agent_last_seen_at
    new_cursor = Time.current
    attempts = 0

    described_class.perform do
      attempts += 1
      expect(conversation.reload.agent_last_seen_at).to eq(original_cursor)
      conversation.update_columns(agent_last_seen_at: new_cursor)
      database_deadlock! if attempts < 3
    end

    expect(attempts).to eq(3)
    expect(conversation.reload.agent_last_seen_at).to be_within(0.001.seconds).of(new_cursor)
  end

  it 'propagates a persistent deadlock after three rolled-back attempts and leaves the connection usable' do
    original_cursor = conversation.agent_last_seen_at
    attempts = 0

    expect do
      described_class.perform do
        attempts += 1
        conversation.update_columns(agent_last_seen_at: Time.current)
        database_deadlock!
      end
    end.to raise_error(ActiveRecord::Deadlocked)

    expect(attempts).to eq(3)
    expect(conversation.reload.agent_last_seen_at).to eq(original_cursor)
  end

  it 'does not retry an unrelated failure' do
    attempts = 0

    expect do
      described_class.perform do
        attempts += 1
        raise ActiveRecord::StatementInvalid, 'Not a deadlock'
      end
    end.to raise_error(ActiveRecord::StatementInvalid, 'Not a deadlock')

    expect(attempts).to eq(1)
  end
end
