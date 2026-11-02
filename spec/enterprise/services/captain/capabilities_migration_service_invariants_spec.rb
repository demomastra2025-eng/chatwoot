require 'rails_helper'

RSpec.describe Captain::CapabilitiesMigrationService do
  let(:account) { create(:account) }
  let(:actor) { create(:super_admin) }
  let(:assistant) do
    create(:captain_assistant, :legacy, account: account, usage_mode: 'internal_assistant', config: {
             'tool_access' => { 'agent' => { 'enabled' => false, 'tool_ids' => [] },
                                'assistant' => { 'enabled' => false, 'tool_ids' => [] } }
           })
  end
  let(:service) { described_class.new(assistant: assistant, actor: actor) }
  let(:policy) { 'preserve_ai_expand_mcp_20261102' }

  around { |example| Captain::Mcp::ToolCatalog.without_discovery { example.run } }

  def expect_invalid_profile(field)
    original = assistant.reload.attributes.deep_dup
    manifest = service.prepare_transition(policy: policy, expected_account_id: account.id)
    expect(manifest[:blockers]).to include('invalid_assistant_metadata')
    expect(manifest[:invalid_fields]).to include(field)
    expect_activation_rejected(manifest)
    expect(assistant.reload.attributes).to eq(original)
  end

  def expect_activation_rejected(manifest)
    expect do
      service.activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: account.id)
    end.to raise_error(Captain::AssistantConfigContract::Violation, 'capability_migration_blocked')
  end

  it 'blocks blank historical required metadata without changing the source' do
    assistant.update_column(:name, '') # rubocop:disable Rails/SkipsModelValidations
    expect_invalid_profile('name')
  end

  it 'blocks a historical internal assistant connected to an inbox' do
    inbox = create(:inbox, account: account)
    channel = create(:captain_inbox, inbox: inbox)
    channel.update_column(:captain_assistant_id, assistant.id) # rubocop:disable Rails/SkipsModelValidations
    expect_invalid_profile('usage_mode')
  end

  it 'retains follow-up validation and exposes only field names' do
    assistant.update_column(:config, assistant.config.merge('follow_up_settings' => { 'steps' => 'invalid' })) # rubocop:disable Rails/SkipsModelValidations
    expect_invalid_profile('config')
  end

  it 'validates agreed nonbinding unknown references only on the isolated migration copy' do
    assistant.update_column(:description, '[Unavailable](tool://unmapped_reference)') # rubocop:disable Rails/SkipsModelValidations
    original = assistant.reload.attributes.deep_dup
    manifest = service.prepare_transition(policy: policy, expected_account_id: account.id)
    expect(manifest[:status]).to eq('ready')
    expect(assistant.attributes).to eq(original)
    normal = Captain::Assistant.find(assistant.id)
    expect(normal.valid?(:capability_policy_transition)).to be(false)
    expect(normal.errors.attribute_names).to include(:description)
    expect(normal.config).to have_key('main_prompt_rules_migration')
    service.activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: account.id)
    expect(assistant.reload.description).to eq(original['description'])
  end

  it 'rejects any other validator callback mutation without changing original attributes' do
    original = assistant.reload.attributes.deep_dup
    allow(Captain::Assistant).to receive(:instantiate).and_wrap_original do |method, *args|
      method.call(*args).tap do |candidate|
        candidate.define_singleton_method(:ensure_usage_mode) do
          self.routing_description = 'synthetic callback mutation'
          config['tool_access']['agent']['tool_ids'] << 'synthetic_mutation'
        end
      end
    end
    manifest = service.prepare_transition(policy: policy, expected_account_id: account.id)
    expect(manifest[:blockers]).to include('assistant_validation_mutates_source')
    expect(manifest[:changed_fields]).to eq(%w[config routing_description])
    expect(assistant.attributes).to eq(original)
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'propagates validation errors and clears its instance context even on failure' do
    original = assistant.reload.attributes.deep_dup
    captured = nil
    allow(Captain::Assistant).to receive(:instantiate).and_wrap_original do |method, *args|
      captured = method.call(*args)
      captured.define_singleton_method(:ensure_usage_mode) { raise 'synthetic validation interruption' }
      captured
    end
    expect { service.prepare_transition(policy: policy, expected_account_id: account.id) }
      .to raise_error(RuntimeError, 'synthetic validation interruption')
    expect(captured.instance_variable_defined?(:@capability_transition_ignored_instruction_tool_ids)).to be(false)
    expect(assistant.validation_context).to be_nil
    expect(assistant.reload.attributes).to eq(original)
  end
end
