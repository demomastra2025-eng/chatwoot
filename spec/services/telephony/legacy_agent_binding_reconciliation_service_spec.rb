require 'rails_helper'

RSpec.describe Telephony::LegacyAgentBindingReconciliationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account) }
  let(:voice_inbox) { voice_channel.inbox }

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: voice_inbox, user: user)
  end

  it 'disables a legacy binding when active SIP profiles cover all user voice inboxes' do
    binding = create(:telephony_agent_binding, :registered, account: account, user: user)
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: user,
      status: 'active',
      enabled: true
    )

    result = described_class.new(account: account).perform

    expect(result).to include(checked: 1, disabled: 1, skipped: 0)
    expect(binding.reload.enabled).to be(false)
    expect(binding.metadata).to include(
      'disabled_reason' => 'superseded_by_native_sip_profiles',
      'disabled_by' => 'telephony_legacy_agent_binding_reconciliation',
      'registration_state' => 'offline',
      'presence' => 'offline',
      'registered' => false,
      'available' => false
    )
    expect(binding.metadata['superseded_by_sip_profile_ids']).to eq([profile.id])
    expect(binding.metadata['superseded_for_inbox_ids']).to eq([voice_inbox.id])
  end

  it 'keeps a legacy binding when another Fonoster voice inbox still has no SIP profile for the user' do
    second_channel = create(:channel_voice, :fonoster, account: account)
    second_inbox = second_channel.inbox
    create(:inbox_member, inbox: second_inbox, user: user)
    binding = create(:telephony_agent_binding, :registered, account: account, user: user)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: user,
      status: 'active',
      enabled: true
    )

    result = described_class.new(account: account).perform

    expect(result).to include(checked: 1, disabled: 0, skipped: 1)
    expect(result[:skip_reasons][:unprofiled_voice_inbox]).to eq(1)
    expect(binding.reload.enabled).to be(true)
  end

  it 'keeps a legacy binding during inbox-scoped reconciliation when another user voice inbox lacks a SIP profile' do
    second_channel = create(:channel_voice, :fonoster, account: account)
    second_inbox = second_channel.inbox
    create(:inbox_member, inbox: second_inbox, user: user)
    binding = create(:telephony_agent_binding, :registered, account: account, user: user)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: user,
      status: 'active',
      enabled: true
    )

    result = described_class.new(account: account, inbox: voice_inbox).perform

    expect(result).to include(checked: 1, disabled: 0, skipped: 1)
    expect(result[:skip_reasons][:unprofiled_voice_inbox]).to eq(1)
    expect(binding.reload.enabled).to be(true)
  end

  it 'keeps a legacy binding when a memberless Fonoster voice inbox can still route account-level bindings' do
    create(:channel_voice, :fonoster, account: account)
    binding = create(:telephony_agent_binding, :registered, account: account, user: user)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: user,
      status: 'active',
      enabled: true
    )

    result = described_class.new(account: account).perform

    expect(result).to include(checked: 1, disabled: 0, skipped: 1)
    expect(result[:skip_reasons][:unprofiled_voice_inbox]).to eq(1)
    expect(binding.reload.enabled).to be(true)
  end

  it 'keeps a legacy binding while an active call session still references it' do
    binding = create(:telephony_agent_binding, :registered, account: account, user: user)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: user,
      status: 'active',
      enabled: true
    )
    conversation = create(:conversation, account: account, inbox: voice_inbox)
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      agent_binding: binding,
      status: 'in_progress'
    )

    result = described_class.new(account: account).perform

    expect(result).to include(checked: 1, disabled: 0, skipped: 1)
    expect(result[:skip_reasons][:active_call_session]).to eq(1)
    expect(binding.reload.enabled).to be(true)
  end

  it 'reports candidates without changing rows in dry-run mode' do
    binding = create(:telephony_agent_binding, :registered, account: account, user: user)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: user,
      status: 'active',
      enabled: true
    )

    result = described_class.new(account: account, dry_run: true).perform

    expect(result).to include(checked: 1, disabled: 1, skipped: 0, dry_run: true)
    expect(result[:binding_ids]).to eq([binding.id])
    expect(binding.reload.enabled).to be(true)
  end
end
