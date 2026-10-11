require 'rails_helper'

RSpec.describe Captain::AccountSettingsBackfill do
  let(:account) { create(:account) }
  let(:older) { create(:captain_assistant, account: account, config: { 'feature_faq' => false }) }
  let(:main) { create(:captain_assistant, account: account, config: { 'feature_faq' => true }) }

  it 'selects the active agent with the most conversations on its AI channel in 30 days' do
    old_inbox = create(:inbox, account: account)
    main_inbox = create(:inbox, account: account)
    create(:captain_inbox, captain_assistant: older, inbox: old_inbox)
    create(:captain_inbox, captain_assistant: main, inbox: main_inbox)
    create(:conversation, account: account, inbox: old_inbox)
    2.times { create(:conversation, account: account, inbox: main_inbox) }

    expect(described_class.main_assistant(account)).to eq(main)
    expect(described_class.backfill!(account)).to be(true)
    expect(Captain::AccountSettings.new(account.reload).section('faq')['generate_from_resolved']).to be(true)
    expect(described_class.backfill!(account)).to be(false)
    expect(main.reload.config['feature_faq']).to be(true)
  end

  it 'falls back to the most recently updated active external agent' do
    older
    main.update!(updated_at: 1.minute.from_now)

    expect(described_class.main_assistant(account)).to eq(main)
  end

  it 'prefers a connected channel agent over a newer unconnected agent when no conversations are recent' do
    inbox = create(:inbox, account: account)
    create(:captain_inbox, captain_assistant: older, inbox: inbox)
    main.update!(updated_at: 1.minute.from_now)

    expect(described_class.main_assistant(account)).to eq(older)
  end

  it 'reports only IDs and differing setting names' do
    older
    main
    conflicts = described_class.conflicts(account)

    expect(conflicts.size).to eq(1)
    expect(conflicts.first[:settings]).to include('faq.generate_from_resolved')
    expect(conflicts.first.keys).to contain_exactly(:account_id, :main_agent_id, :agent_id, :settings)
  end

  it 'copies the main agent custom rules without changing the old stored rules' do
    rule = { 'id' => 'urgent_1', 'name' => 'Urgent request', 'direction' => 'input',
             'instruction' => 'Route a fictional emergency.', 'action' => 'handoff', 'enabled' => true, 'message' => '' }
    main.update!(config: main.config.merge('safety_settings' => { 'custom_rules' => [rule] }))

    described_class.backfill!(account)

    expect(Captain::AccountSettings.new(account.reload).section('safety')['custom_rules'])
      .to include(include('id' => 'urgent_1', 'direction' => 'inbound'))
    expect(main.reload.config.dig('safety_settings', 'custom_rules')).to eq([rule])
  end
end
