# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeAccessSnapshotBuilder do
  let(:account) { create(:account) }

  def select_count(&)
    queries = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      queries << payload[:sql] if payload[:sql].start_with?('SELECT') && payload[:name] != 'SCHEMA'
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    queries.length
  end

  it 'builds access snapshots in a fixed number of queries as account users grow' do
    create(:user, account: account)
    baseline_count = select_count { described_class.new(account, []).perform }

    create_list(:user, 2, account: account)
    expanded_count = select_count { described_class.new(account, []).perform }

    expect(expanded_count).to eq(baseline_count)
  end

  it 'marks canonical participants in the prefetched snapshot' do
    participant = create(:user, account: account)

    contexts = described_class.new(account, [participant.id]).perform

    expect(contexts.dig(participant.id, :thread_access_snapshot, :participant)).to be(true)
  end
end
