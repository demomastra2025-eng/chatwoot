# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_widget, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, status: :pending) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:origin) do
    {
      'assistant_id' => assistant.id,
      'conversation_id' => conversation.id,
      'control_generation' => conversation.current_captain_control_generation
    }
  end
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, operation: 'create_patient', status: 'v2_queued',
      idempotency_key: SecureRandom.uuid, execution_state: { 'captain_action_origin' => origin }
    )
  end
  let(:executor) { instance_double(Integrations::Medelement::ProviderCommands::Executor, perform: true) }

  before do
    account.enable_features!('scheduling')
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    allow(Integrations::Medelement::ProviderCommands::Executor).to receive(:new).and_return(executor)
  end

  it 'fails closed for a queued Captain command even while AI still owns the conversation' do
    described_class.perform_now(command.id)

    expect(executor).not_to have_received(:perform)
    expect(command.reload).to have_attributes(status: 'cancelled', last_error_code: 'captain_provider_contract_unavailable')
  end

  it 'cancels a queued provider command before remote write when human takes over' do
    queued = command
    conversation.activate_captain_human_control!(source: 'agent_reply')

    described_class.perform_now(queued.id)

    expect(executor).not_to have_received(:perform)
    expect(queued.reload).to have_attributes(status: 'cancelled', last_error_code: 'captain_control_stale')
  end

  it 'does not replay the old command after AI is reactivated' do
    queued = command
    conversation.activate_captain_human_control!(source: 'agent_reply')
    conversation.prepare_captain_ai_control!

    described_class.perform_now(queued.id)

    expect(executor).not_to have_received(:perform)
    expect(queued.reload).to be_cancelled
  end

  it 'does not cancel non-Captain provider commands on a human takeover' do
    command.update!(execution_state: {})
    conversation.activate_captain_human_control!(source: 'agent_reply')

    described_class.perform_now(command.id)

    expect(executor).to have_received(:perform).once
  end

  it 'does not retry or resume a denied provider command after AI is reactivated' do
    described_class.perform_now(command.id)
    conversation.activate_captain_human_control!(source: 'manual_assignment')
    conversation.prepare_captain_ai_control!

    described_class.perform_now(command.id)
    expect(executor).not_to have_received(:perform)
    expect(command.reload).to have_attributes(status: 'cancelled', last_error_code: 'captain_provider_contract_unavailable')
  end

  it 'leaves a processing command for reconciliation rather than declaring a remote effect cancelled' do
    command.update!(status: 'v2_processing', execution_state: command.execution_state.merge('write_phase' => 'patient_create'))
    described_class.perform_now(command.id)

    expect(executor).not_to have_received(:perform)
    expect(command.reload).to have_attributes(status: 'v2_processing')
    expect(command.execution_state['write_phase']).to eq('patient_create')
  end
end
