require 'rails_helper'

RSpec.describe Captain::AccountSettingsBackfill do
  let(:account) { create(:account) }
  let(:older) { create(:captain_assistant, account: account, config: { 'feature_faq' => false }) }
  let(:main) { create(:captain_assistant, account: account, config: { 'feature_faq' => true }) }

  it 'seeds the workspace settings from the most recently changed enabled agent, with no channel or main agent involved' do
    older
    main.update!(updated_at: 1.minute.from_now)
    create(:conversation, account: account, inbox: create(:inbox, account: account))

    expect(described_class.reference_assistant(account)).to eq(main)
    expect(described_class.backfill!(account)).to be(true)
    expect(Captain::AccountSettings.new(account.reload).section('faq')['generate_from_resolved']).to be(true)
    expect(described_class.backfill!(account)).to be(false)
    expect(main.reload.config['feature_faq']).to be(true)
  end

  it 'ignores a disabled agent and an internal assistant' do
    older
    main.update!(updated_at: 1.minute.from_now, active: false)
    create(:captain_assistant, account: account, usage_mode: 'internal_assistant', updated_at: 2.minutes.from_now)

    expect(described_class.reference_assistant(account)).to eq(older)
  end

  it 'has no reference agent in a workspace with no enabled agent' do
    main.update!(active: false)

    expect(described_class.reference_assistant(account)).to be_nil
  end

  it 'reports only IDs and differing setting names' do
    older
    main.update!(updated_at: 1.minute.from_now)
    conflicts = described_class.conflicts(account)

    expect(conflicts.size).to eq(1)
    expect(conflicts.first[:settings]).to include('faq.generate_from_resolved')
    expect(conflicts.first.keys).to contain_exactly(:account_id, :reference_agent_id, :agent_id, :settings)
    expect(conflicts.first).to include(reference_agent_id: main.id, agent_id: older.id)
  end

  describe 'the handoff and closing messages of the old per-agent settings' do
    let(:wishes) { "  Коротко и вежливо,\nбез обещаний по срокам.  " }
    let(:legacy_config) do
      { 'handoff_message_enabled' => true, 'handoff_message_mode' => 'ai', 'handoff_message' => wishes,
        'resolution_message_enabled' => true, 'resolution_message_mode' => 'static', 'resolution_message' => 'Диалог закрыт.' }
    end

    before { create(:captain_assistant, account: account, config: legacy_config) }

    it 'moves the wishes of an AI-mode message into the instruction, never into the text a customer can get' do
      described_class.backfill!(account)

      handoff = Captain::AccountSettings.new(account.reload).section('handoff')
      expect(handoff['handoff_message']).to include(
        'enabled' => true, 'mode' => 'generated', 'text' => '', 'instruction' => 'Коротко и вежливо, без обещаний по срокам.'
      )
    end

    it 'keeps the text of a fixed message as it was' do
      described_class.backfill!(account)

      expect(Captain::AccountSettings.new(account.reload).section('handoff')['resolution_message'])
        .to include('mode' => 'fixed', 'text' => 'Диалог закрыт.', 'instruction' => '')
    end

    it 'cuts the wishes to the instruction limit' do
      other = create(:account)
      create(:captain_assistant, account: other, config: legacy_config.merge('handoff_message' => 'очень ' * 200))

      described_class.backfill!(other)

      instruction = Captain::AccountSettings.new(other.reload).section('handoff').dig('handoff_message', 'instruction')
      expect(instruction.length).to eq(Captain::AccountSettings::MESSAGE_INSTRUCTION_MAX_LENGTH)
    end
  end

  describe '.move_message_guidance!' do
    def save_messages(handoff:, resolution:)
      Captain::AccountSettings.new(account).update!('handoff' => { 'handoff_message' => handoff, 'resolution_message' => resolution })
    end

    def messages
      Captain::AccountSettings.new(account.reload).section('handoff').slice('handoff_message', 'resolution_message')
    end

    it 'moves the text of an AI-mode message into its empty instruction and clears the text, once' do
      save_messages(
        handoff: { 'enabled' => true, 'mode' => 'generated', 'text' => ' Коротко и тепло. ', 'instruction' => '' },
        resolution: { 'enabled' => true, 'mode' => 'generated', 'text' => 'Поблагодарите.', 'instruction' => '' }
      )

      expect(described_class.move_message_guidance!(account)).to eq(%w[handoff_message resolution_message])

      expect(messages['handoff_message']).to include('mode' => 'generated', 'text' => '', 'instruction' => 'Коротко и тепло.')
      expect(messages['resolution_message']).to include('text' => '', 'instruction' => 'Поблагодарите.')
      expect(described_class.move_message_guidance!(account)).to eq([])
    end

    it 'leaves fixed messages, messages that already have an instruction and AI messages without text alone' do
      save_messages(
        handoff: { 'enabled' => true, 'mode' => 'fixed', 'text' => 'Подключаем сотрудника.', 'instruction' => '' },
        resolution: { 'enabled' => true, 'mode' => 'generated', 'text' => 'Запасной текст', 'instruction' => 'Уже описано.' }
      )
      before_state = messages

      expect(described_class.move_message_guidance!(account)).to eq([])

      expect(messages).to eq(before_state)
      save_messages(handoff: { 'mode' => 'generated', 'text' => '  ' }, resolution: { 'mode' => 'fixed' })
      expect(described_class.move_message_guidance!(account)).to eq([])
    end

    it 'only reports what it would move on a dry run' do
      save_messages(
        handoff: { 'enabled' => true, 'mode' => 'generated', 'text' => 'Коротко.', 'instruction' => '' },
        resolution: { 'enabled' => true, 'mode' => 'fixed', 'text' => 'Закрыто.', 'instruction' => '' }
      )

      expect(described_class.move_message_guidance!(account, dry_run: true)).to eq(['handoff_message'])

      expect(messages['handoff_message']).to include('text' => 'Коротко.', 'instruction' => '')
    end

    it 'does nothing for an account without stored account settings' do
      expect(described_class.move_message_guidance!(account)).to eq([])
      expect(account.reload.settings.to_h).not_to have_key(Captain::AccountSettings::KEY)
    end
  end

  it 'copies the custom rules of the reference agent without changing the old stored rules' do
    rule = { 'id' => 'urgent_1', 'name' => 'Urgent request', 'direction' => 'input',
             'instruction' => 'Route a fictional emergency.', 'action' => 'handoff', 'enabled' => true, 'message' => '' }
    main.update!(config: main.config.merge('safety_settings' => { 'custom_rules' => [rule] }))

    described_class.backfill!(account)

    expect(Captain::AccountSettings.new(account.reload).section('safety')['custom_rules'])
      .to include(include('id' => 'urgent_1', 'direction' => 'inbound'))
    expect(main.reload.config.dig('safety_settings', 'custom_rules')).to eq([rule])
  end
end
