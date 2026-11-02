require 'rails_helper'
require 'rake'

RSpec.describe Captain::Capabilities do
  let(:account) { create(:account) }
  let(:assistant) do
    create(:captain_assistant, :legacy, account: account, usage_mode: 'internal_assistant', description: 'Private inventory instructions', config: {
             'tool_access' => {
               'agent' => { 'enabled' => false, 'tool_ids' => [] },
               'assistant' => { 'enabled' => false, 'tool_ids' => [] }
             }
           })
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('captain:capabilities:plan')
    %w[plan preflight activate].each { |name| Rake::Task["captain:capabilities:#{name}"].reenable }
  end

  it 'defaults activation to a read-only report without printing instructions' do
    original = assistant.attributes.deep_dup
    with_modified_env('ASSISTANT_ID' => assistant.id.to_s, 'CONFIRM' => nil) do
      expect { Rake::Task['captain:capabilities:activate'].invoke }
        .to output(/\A(?!.*Private inventory).*"status":"ready".*"source_digest"/m).to_stdout
    end
    expect(assistant.reload.attributes).to eq(original)
  end

  it 'fails release preflight while an unmigrated assistant remains' do
    assistant
    with_modified_env('ACCOUNT_ID' => account.id.to_s) do
      expect do
        expect { Rake::Task['captain:capabilities:preflight'].invoke }.to raise_error(SystemExit)
      end.to output(/"pending":\[.*"assistant_id":#{assistant.id}/).to_stdout
                                                                   .and output(/Capability cutover is incomplete/).to_stderr
    end
  end

  it 'requires an explicit digest activation and then passes release preflight' do
    actor = create(:super_admin)
    source_digest = Captain::ToolAccessMigrationPlan.for(assistant)[:source_digest]
    with_modified_env('ASSISTANT_ID' => assistant.id.to_s, 'ACTOR_ID' => actor.id.to_s, 'CONFIRM' => 'yes', 'SOURCE_DIGEST' => source_digest) do
      expect { Rake::Task['captain:capabilities:activate'].invoke }.to output(/"status":"migrated"/).to_stdout
    end
    with_modified_env('ACCOUNT_ID' => account.id.to_s) do
      expect { Rake::Task['captain:capabilities:preflight'].invoke }
        .to output(/"pending":\[\],"invalid_assistant_ids":\[\]/).to_stdout
    end
    expect(described_class.valid?(assistant.reload.config['capabilities'])).to be(true)
  end
end
