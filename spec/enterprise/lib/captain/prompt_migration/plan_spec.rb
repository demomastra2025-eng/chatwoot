# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptMigration::Plan do
  let(:account) { create(:account) }
  let!(:admin) do
    create(:captain_assistant, account: account, name: 'Администратор Intermedical',
                               description: "Ты — главный ИИ-администратор и координатор клиники.\nЗаписывай к врачам.",
                               routing_description: 'Главный координатор и администратор: запись к врачам')
  end
  let!(:nurse) do
    create(:captain_assistant, account: account, name: 'Медсестра',
                               description: "Ты — медсестра.\n#{transfer_line}\nАнализы.",
                               routing_description: 'Анализы и справки')
  end
  let(:transfer_line) { '- При запросе на запись к врачу переведи диалог агенту «Администратор Intermedical».' }
  let(:file) { Rails.root.join('tmp', "router-prompts-#{SecureRandom.hex(4)}.yml").to_s }
  let(:proposals) do
    {
      'migration' => '2026-10-router',
      'assistants' => [
        { 'account_id' => account.id, 'assistant_id' => admin.id, 'routing_description' => 'Общие вопросы о клинике. Запись к врачам.',
          'description_edits' => [{ 'find' => 'главный ИИ-администратор и координатор', 'replace' => 'ИИ-администратор' }] },
        { 'account_id' => account.id, 'assistant_id' => nurse.id, 'description_edits' => [{ 'find' => "\n#{transfer_line}", 'replace' => '' }] }
      ]
    }
  end

  before { File.write(file, proposals.to_yaml) }
  after { FileUtils.rm_f(file) }

  def plan = described_class.new(file: file)

  it 'shows per-assistant diffs and lint in a dry run and writes nothing' do
    report = Captain::PromptMigration::Report.new(plan).to_s

    expect(report).to include("assistant #{admin.id} Администратор Intermedical [OK]")
    expect(report).to include('-Ты — главный ИИ-администратор и координатор клиники.', '+Ты — ИИ-администратор клиники.')
    expect(report).to include('+++ routing_description (proposed)', '+Общие вопросы о клинике. Запись к врачам.')
    expect(report).to include("assistant #{nurse.id} Медсестра [OK]")
    expect(report).to include("plan digest: #{plan.digest}")
    expect(admin.reload.description).to start_with('Ты — главный ИИ-администратор')
    expect(nurse.reload.description).to include('переведи диалог')
  end

  it 'lints the proposed texts for transfers, coordinator wording and names of other agents' do
    stale = proposals.deep_dup
    stale['assistants'][1]['description_edits'] = []
    File.write(file, stale.to_yaml)

    nurse_entry = plan.entries.find { |entry| entry.assistant_id == nurse.id }
    expect(nurse_entry.status).to eq('unchanged')
    expect(nurse_entry.errors.map { |finding| finding[:code] }).to include('handoff_wording', 'other_agent_name')
    expect(plan.entries.find { |entry| entry.assistant_id == admin.id }.errors).to be_empty
  end

  it 'refuses to write without the digest of the reviewed dry run' do
    expect { Captain::PromptMigration::Applier.new(plan, confirm: 'wrong') }.to raise_error(Captain::PromptMigration::Applier::ConfirmationError)
    expect(admin.reload.description).to start_with('Ты — главный')
  end

  it 'writes what the dry run showed with the digest and keeps the old texts for the rollback' do
    reviewed = plan
    outcome = Captain::PromptMigration::Applier.new(reviewed, confirm: reviewed.digest).apply!

    expect(outcome.applied).to contain_exactly(admin.id, nurse.id)
    expect(admin.reload.description).to eq("Ты — ИИ-администратор клиники.\nЗаписывай к врачам.")
    expect(admin.routing_description).to eq('Общие вопросы о клинике. Запись к врачам.')
    expect(nurse.reload.description).to eq("Ты — медсестра.\nАнализы.")
    expect(admin.config['prompt_history'].last)
      .to include('migration' => '2026-10-router', 'routing_description' => 'Главный координатор и администратор: запись к врачам')
  end

  it 'skips an agent whose stored text changed after the dry run' do
    reviewed = plan
    admin.update!(description: 'Ты — ИИ-администратор, текст изменён после ревью.')

    outcome = Captain::PromptMigration::Applier.new(reviewed, confirm: reviewed.digest).apply!

    expect(outcome.skipped).to eq([admin.id])
    expect(admin.reload.description).to eq('Ты — ИИ-администратор, текст изменён после ревью.')
  end

  it 'never applies a pinned proposal whose base digest no longer matches, nor an edit that is not found' do
    pinned = proposals.deep_dup
    pinned['assistants'][0]['base_digest'] = 'sha256:outdated'
    pinned['assistants'][1]['description_edits'] = [{ 'find' => 'текста нет', 'replace' => 'x' }]
    File.write(file, pinned.to_yaml)

    expect(plan.entries.map(&:status)).to eq(%w[drift edit_not_found])
    expect(plan.applicable).to be_empty
    expect(plan.drift_count).to eq(2)
  end

  it 'rolls a migration back with the same confirmation' do
    reviewed = plan
    Captain::PromptMigration::Applier.new(reviewed, confirm: reviewed.digest).apply!
    rollback = Captain::PromptMigration::Rollback.new(migration: '2026-10-router')

    expect { rollback.apply!(confirm: 'wrong') }.to raise_error(Captain::PromptMigration::Applier::ConfirmationError)
    restored = rollback.apply!(confirm: rollback.digest)

    expect(restored).to contain_exactly(admin.id, nurse.id)
    expect(admin.reload.description).to start_with('Ты — главный ИИ-администратор')
    expect(admin.config['prompt_history']).to be_empty
  end

  it 'reads the committed proposal file' do
    committed = YAML.safe_load_file(Rails.root.join('config/captain/router_prompt_migration/2026-10-router.yml'))

    expect(committed['migration']).to eq('2026-10-router')
    expect(committed['assistants'].pluck('assistant_id')).to include(84, 119, 120, 85, 90, 113, 114, 77, 108, 109)
    committed['assistants'].each do |row|
      expect(Captain::Routing::CardLint.forbidden_words(row['routing_description'])).to be_empty
      expect(row['routing_description'].length).to be <= Captain::Routing::CompetenceCard::MAX_LENGTH
    end
  end
end
