# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260924090714_ensure_captain_takeover_control_columns')

RSpec.describe EnsureCaptainTakeoverControlColumns do
  it 'retains an existing human thread on a partially migrated schema and stays idempotent' do
    account = create(:account)
    account.enable_features!('communication_threads')
    conversation = create(:conversation, account: account)
    thread = conversation.communication_thread
    original_handoff = 2.hours.ago
    thread.update_columns( # rubocop:disable Rails/SkipsModelValidations
      captain_control_state: 'human', captain_control_generation: 0, captain_handoff_applied_at: original_handoff
    )
    conversation.update_columns(captain_control_state: 'ai', captain_control_generation: 2) # rubocop:disable Rails/SkipsModelValidations

    described_class.new.up

    expect(thread.reload.captain_control_state).to eq('human')
    expect(thread.captain_control_generation).to eq(3)
    expect(thread.captain_handoff_applied_at).to be_within(1.second).of(original_handoff)

    described_class.new.up
    expect(thread.reload.captain_control_generation).to eq(3)
  end

  it 'reconciles a linked human channel even if the existing AI thread has a positive generation' do
    account = create(:account)
    account.enable_features!('communication_threads')
    conversation = create(:conversation, account: account)
    thread = conversation.communication_thread
    conversation.update_columns(captain_control_state: 'human', captain_control_generation: 2) # rubocop:disable Rails/SkipsModelValidations
    thread.update_columns(captain_control_state: 'ai', captain_control_generation: 4) # rubocop:disable Rails/SkipsModelValidations

    described_class.new.up

    expect(thread.reload.captain_control_state).to eq('human')
    expect(thread.captain_control_generation).to eq(5)
    described_class.new.up
    expect(thread.reload.captain_control_generation).to eq(5)
  end
end
