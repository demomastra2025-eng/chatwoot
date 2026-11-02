require 'rails_helper'
require 'rake'

RSpec.describe Captain::Capabilities do
  let(:actor) { create(:super_admin) }
  let(:assistant) { create(:captain_assistant, :legacy, description: 'Private operator instructions') }
  let(:policy) { 'preserve_ai_expand_mcp_20261102' }

  around { |example| Captain::Mcp::ToolCatalog.without_discovery { example.run } }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('captain:capabilities:plan')
    %w[plan preflight activate].each { |name| Rake::Task["captain:capabilities:#{name}"].reenable }
  end

  it 'prepares a read-only per-account actor-bound manifest, then explicitly activates the exact digest' do
    original = assistant.attributes.deep_dup
    env = { 'TRANSITION_POLICY' => policy, 'ASSISTANT_ID' => assistant.id.to_s,
            'ACCOUNT_ID' => assistant.account_id.to_s, 'ACTOR_ID' => actor.id.to_s, 'CONFIRM' => nil }
    with_modified_env(**env) do
      expect { Rake::Task['captain:capabilities:plan'].invoke }
        .to output(/"policy":"#{policy}".*"status":"ready".*"before":.*"after":.*"source_digest"/m).to_stdout
    end
    expect(assistant.reload.attributes).to eq(original)
    manifest = Captain::CapabilitiesMigrationService.new(assistant: assistant, actor: actor)
                                                    .prepare_transition(policy: policy, expected_account_id: assistant.account_id)
    with_modified_env(**env, 'CONFIRM' => 'yes', 'SOURCE_DIGEST' => manifest[:source_digest]) do
      expect { Rake::Task['captain:capabilities:activate'].invoke }.to output(/"status":"migrated"/).to_stdout
    end
    expect(assistant.reload.config).to have_key('capabilities')
  end

  it 'requires explicit account and platform actor for policy dry runs' do
    with_modified_env('TRANSITION_POLICY' => policy, 'ASSISTANT_ID' => assistant.id.to_s, 'CONFIRM' => nil, 'ACTOR_ID' => nil) do
      expect { Rake::Task['captain:capabilities:activate'].invoke }.to raise_error(KeyError, /ACTOR_ID/)
    end
    expect(assistant.reload.config).not_to have_key('capabilities')
  end
end
