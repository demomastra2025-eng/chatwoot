require 'rails_helper'
require Rails.root.join('db/migrate/20261011081000_create_captain_knowledge_grants')

RSpec.describe CreateCaptainKnowledgeGrants do
  it 'backfills converted scenario agents with parent personal access and leaves unrelated agents private' do
    account = create(:account)
    parent = create(:captain_assistant, account: account)
    scenario = create(:captain_scenario, account: account, assistant: parent)
    converted = create(:captain_assistant, account: account, legacy_scenario_id: scenario.id)
    unrelated = create(:captain_assistant, account: account)
    document = create(:captain_document, account: account, assistant: parent, visibility: :personal)
    faq = create(:captain_assistant_response, account: account, assistant: parent, visibility: :personal)
    general = create(:captain_document, account: account, assistant: parent, visibility: :general)
    legacy_workspace = create(:captain_document, account: account, assistant: nil, visibility: :personal)

    2.times { described_class.new.send(:backfill_converted_agent_access) }

    expect(Captain::Document.visible_to_assistant(converted.id)).to include(document, general, legacy_workspace)
    expect(Captain::AssistantResponse.visible_to_assistant(converted.id)).to include(faq)
    expect(Captain::Document.visible_to_assistant(unrelated.id)).not_to include(document)
    expect(document.knowledge_grants.where(assistant: converted).count).to eq(1)
    expect(faq.knowledge_grants.where(assistant: converted).count).to eq(1)
    expect(general.knowledge_grants).to be_empty
    expect(legacy_workspace.knowledge_grants).to be_empty
    expect(document.reload.assistant_id).to eq(parent.id)
    expect(document).to be_visibility_personal
  end

  it 'finishes every private grant across bounded batches and retains unique access on a full migration rerun' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    account = create(:account)
    parent = create(:captain_assistant, account: account)
    converted = Array.new(2) do
      scenario = create(:captain_scenario, account: account, assistant: parent)
      create(:captain_assistant, account: account, legacy_scenario_id: scenario.id)
    end
    documents = create_list(:captain_document, 3, account: account, assistant: parent, visibility: :personal)
    original = documents.map(&:attributes)

    2.times { ActiveRecord::Migration.suppress_messages { described_class.new.up } }

    converted.each do |agent|
      expect(Captain::Document.visible_to_assistant(agent.id)).to include(*documents)
      expect(Captain::KnowledgeGrant.where(assistant: agent, knowledge_record_type: 'Captain::Document').pluck(:knowledge_record_id))
        .to match_array(documents.map(&:id))
    end
    expect(documents.map { |document| document.reload.attributes }).to eq(original)
    expect(Captain::KnowledgeGrant.where(assistant: converted).count).to eq(6)
    expect(ActiveRecord::Base.connection.foreign_keys(:captain_knowledge_grants)).to all(be_validated)
  end

  it 'creates the type check NOT VALID, rejects new unsupported record types, and validates the retained rows' do
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint :captain_knowledge_grants, name: 'captain_knowledge_grants_record_type'
    migration = described_class.new
    ActiveRecord::Migration.suppress_messages { migration.send(:add_constraints) }
    check = connection.check_constraints(:captain_knowledge_grants).find { |constraint| constraint.name == 'captain_knowledge_grants_record_type' }
    expect(check.validate?).to be false
    assistant = create(:captain_assistant)

    expect do
      connection.transaction(requires_new: true) do
        connection.execute <<~SQL.squish
          INSERT INTO captain_knowledge_grants (account_id, assistant_id, knowledge_record_type, knowledge_record_id, created_at, updated_at)
          VALUES (#{assistant.account_id}, #{assistant.id}, 'UnsupportedRecord', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /captain_knowledge_grants_record_type/)

    ActiveRecord::Migration.suppress_messages { migration.send(:validate_constraints) }
    expect(connection.check_constraints(:captain_knowledge_grants).find { |constraint| constraint.name == check.name }.validate?).to be true
  end

  it 'refuses to erase retained personal access in an application rollback' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
