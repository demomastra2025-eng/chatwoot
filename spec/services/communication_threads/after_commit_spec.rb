# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::AfterCommit do
  self.use_transactional_tests = false

  it 'runs a callback only after the surrounding transaction commits' do
    calls = 0

    ApplicationRecord.transaction do
      described_class.run { calls += 1 }
      expect(calls).to eq(0)
    end

    expect(calls).to eq(1)
  end

  it 'discards a callback when the surrounding transaction rolls back' do
    calls = 0

    ApplicationRecord.transaction do
      described_class.run { calls += 1 }
      raise ActiveRecord::Rollback
    end

    expect(calls).to eq(0)
  end
end
