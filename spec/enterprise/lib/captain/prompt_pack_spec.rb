# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

# rake onelink:captain:apply_prompt_pack FILE=<prompts-v2 pack> [APPLY=1] [VERBOSE=1] | RESTORE=<backup> [APPLY=1]: the clinic block
# and the prompt and card of the listed agents of one clinic, with a backup first and a way back. The fixture names account 990043
# and its agents 990077 and 990109.
RSpec.describe Captain::PromptPack do
  let(:fixture_path) { Rails.root.join('spec/fixtures/files/prompts_v2/clinic_990043.json').to_s }
  let(:payload) { JSON.parse(File.read(fixture_path)) }
  let(:backup_dir) { Dir.mktmpdir('prompt-pack') }
  let!(:account) do
    create(:account, id: 990_043, name: 'МО Тест').tap do |record|
      record.update_columns(internal_attributes: { 'medelement_note' => 'keep' }, settings: {}) # rubocop:disable Rails/SkipsModelValidations
    end
  end
  let!(:gynecology) do
    create(:captain_assistant, id: 990_077, account: account, name: 'Гинекология', description: 'Старый промпт гинекологии.',
                               routing_description: 'Главный агент: всё остальное.')
  end
  let!(:ultrasound) { create(:captain_assistant, id: 990_109, account: account, name: 'УЗИ', description: 'Старый промпт УЗИ.') }
  let!(:unlisted) { create(:captain_assistant, account: account, name: 'Жалобы', description: 'Жалобы.', routing_description: 'Жалобы.') }
  let(:tempfiles) { [] }
  let(:out) { StringIO.new }

  # Every run of an example prints into the same out
  def pack(verbose: false)
    described_class.new(out: out, backup_dir: backup_dir, verbose: verbose)
  end

  def printed
    out.string
  end

  def write_json(data)
    file = Tempfile.new(['prompt_pack', '.json'])
    file.write(data.is_a?(String) ? data : JSON.generate(data))
    file.close
    tempfiles << file
    file.path
  end

  def snapshot
    [Account.where(id: account.id).pluck(:internal_attributes, :settings, :updated_at),
     Captain::Assistant.where(account_id: account.id).order(:id).map(&:attributes)]
  end

  def backups
    Dir.glob(File.join(backup_dir, 'prompt_pack_backup_*.json'))
  end

  after do
    tempfiles.each(&:unlink)
    FileUtils.remove_entry(backup_dir)
  end

  describe 'a dry run' do
    it 'prints what changes with the lengths in characters, no texts, and writes nothing, not even a backup', :aggregate_failures do
      before = snapshot

      expect(pack.apply_file(fixture_path)).to be_nil

      expect(snapshot).to eq(before)
      expect(backups).to be_empty
      context_length = payload['shared_block'].strip.length
      prompt_length = payload['assistants'].first['description'].length
      expect(printed).to start_with("Prompt texts of account 990043 «МО Тест» from the pack #{fixture_path}: dry run, nothing is written")
      expect(printed).to include(
        "~ clinic block: 0 -> #{context_length} chars\n",
        "~ assistant 990077 «Гинекология» prompt (description): 26 -> #{prompt_length} chars\n",
        "~ assistant 990077 «Гинекология» card (routing_description): 29 -> #{payload['assistants'].first['routing_description'].length} chars\n",
        '~ assistant 990109 «УЗИ» card (routing_description): 0 -> '
      )
      expect(printed).to end_with("Would write: clinic block changed; agents changed: 990077, 990109 (listed: 990077, 990109).\n")
      expect(printed).not_to include('Клиника:', 'Направление:', 'Жалобы', '---', '+++')
    end

    it 'adds a unified diff of every changed text with VERBOSE' do
      pack(verbose: true).apply_file(fixture_path)

      expect(printed).to include("--- clinic block (stored)\n+++ clinic block (wanted)\n@@ -0,0 +1,9 @@\n+Клиника:\n",
                                "-Старый промпт гинекологии.\n+Направление:\n")
    end
  end

  describe 'apply' do
    it 'backs the stored texts up, then writes the clinic block and the prompt and card of every listed agent', :aggregate_failures do
      backup = pack.apply_file(fixture_path, apply: true)

      expect(backups).to eq([backup])
      expect(File.basename(backup)).to match(/\Aprompt_pack_backup_990043_\d{8}-\d{6}-\d{3}\.json\z/)
      expect(File.stat(backup).mode & 0o777).to eq(0o600)
      expect(JSON.parse(File.read(backup))).to include(
        'kind' => 'onelink_prompt_pack_backup', 'version' => 1, 'account_id' => 990_043, 'source' => "pack #{fixture_path}",
        'clinic_context' => '',
        'assistants' => [
          { 'id' => 990_077, 'description' => 'Старый промпт гинекологии.', 'routing_description' => 'Главный агент: всё остальное.' },
          { 'id' => 990_109, 'description' => 'Старый промпт УЗИ.', 'routing_description' => nil }
        ]
      )
      expect(account.reload.captain_clinic_context).to eq(payload['shared_block'].strip)
      payload['assistants'].each do |entry|
        expect(Captain::Assistant.find(entry['id'])).to have_attributes(entry.slice('description', 'routing_description'))
      end
      expect(printed).to include('writing in one transaction',
                                "Written: clinic block changed; agents changed: 990077, 990109 (listed: 990077, 990109).\n",
                                "Backup of the stored texts: #{backup}\nRoll back with: RESTORE=#{backup} APPLY=1\n")
    end

    it 'touches nothing else: no unlisted agent, no other attribute of an agent or of the account', :aggregate_failures do
      unlisted_before = unlisted.reload.attributes
      ultrasound_before = ultrasound.reload.attributes.except('description', 'routing_description', 'updated_at')

      pack.apply_file(fixture_path, apply: true)

      expect(unlisted.reload.attributes).to eq(unlisted_before)
      expect(ultrasound.reload.attributes.except('description', 'routing_description', 'updated_at')).to eq(ultrasound_before)
      account.reload
      expect(account.internal_attributes).to eq('medelement_note' => 'keep', 'captain_clinic_context' => payload['shared_block'].strip)
      expect(account.settings).to eq({})
    end

    it 'is idempotent: a second run writes nothing and makes no backup', :aggregate_failures do
      pack.apply_file(fixture_path, apply: true)
      state = snapshot

      expect(pack.apply_file(fixture_path, apply: true)).to be_nil

      expect(snapshot).to eq(state)
      expect(backups.size).to eq(1)
      expect(printed).to include('= clinic block: unchanged', '= assistant 990109 «УЗИ» card (routing_description): unchanged',
                                'Nothing written, every text is stored already (clinic block unchanged; agents changed: none')
    end

    it 'writes only what differs' do
      gynecology.update!(payload['assistants'].first.slice('description', 'routing_description'))
      gynecology_updated_at = gynecology.reload.updated_at

      pack.apply_file(fixture_path, apply: true)

      expect(gynecology.reload.updated_at).to eq(gynecology_updated_at)
      expect(printed).to include('agents changed: 990109 (listed: 990077, 990109)')
    end

    it 'writes nothing at all when a later write fails: one transaction' do
      before = snapshot
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(Captain::Assistant).to receive(:save!).and_wrap_original do |method, *args|
        raise ActiveRecord::RecordNotSaved, 'disk full' if method.receiver.id == ultrasound.id

        method.call(*args)
      end
      # rubocop:enable RSpec/AnyInstance

      expect { pack.apply_file(fixture_path, apply: true) }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(snapshot).to eq(before)
    end

    it 'writes nothing when the backup cannot be written' do
      file_in_the_way = File.join(backup_dir, 'not-a-directory')
      File.write(file_in_the_way, 'x')
      before = snapshot

      expect { described_class.new(out: StringIO.new, backup_dir: file_in_the_way).apply_file(fixture_path, apply: true) }
        .to raise_error(SystemCallError)
      expect(snapshot).to eq(before)
    end
  end

  describe 'restore' do
    let!(:backup) { pack.apply_file(fixture_path, apply: true) }

    it 'makes a dry run by default' do
      state = snapshot

      pack.restore(backup)

      expect(snapshot).to eq(state)
      expect(printed).to include("from the backup #{backup} (taken at ", 'dry run, nothing is written',
                                "~ clinic block: #{payload['shared_block'].strip.length} -> 0 chars")
    end

    it 'writes the stored texts back, backing the current ones up first', :aggregate_failures do
      second_backup = pack.restore(backup, apply: true)

      expect(account.reload.internal_attributes).to eq('medelement_note' => 'keep')
      expect(gynecology.reload).to have_attributes(description: 'Старый промпт гинекологии.',
                                                   routing_description: 'Главный агент: всё остальное.')
      expect(ultrasound.reload).to have_attributes(description: 'Старый промпт УЗИ.', routing_description: nil)
      expect(backups).to contain_exactly(backup, second_backup)
      expect(JSON.parse(File.read(second_backup))['clinic_context']).to eq(payload['shared_block'].strip)
      expect(pack.restore(backup, apply: true)).to be_nil
    end

    it 'refuses a file that is not a backup of this task' do
      expect { pack.restore(fixture_path) }.to raise_error(described_class::Refused, /not a prompt pack backup: kind must be/)
      data = JSON.parse(File.read(backup))
      expect { pack.restore(write_json(data.merge('assistants' => [{ 'id' => 990_077 }]))) }
        .to raise_error(described_class::Refused, /assistants\[0\] must have exactly the keys id, description, routing_description/)
      expect { pack.restore(write_json(data.except('source'))) }.to raise_error(described_class::Refused, /exactly the keys/)
      expect { pack.restore('/nonexistent/backup.json') }.to raise_error(described_class::Refused, 'file not found: /nonexistent/backup.json')
    end
  end

  describe 'what it refuses, with nothing written and no backup' do
    def expect_refused(path, message, apply: true)
      before = snapshot

      expect { pack.apply_file(path, apply: apply) }.to raise_error(described_class::Refused, message)
      expect(snapshot).to eq(before)
      expect(backups).to be_empty
    end

    it 'refuses an agent of another account and names its account, on a dry run too' do
      other = create(:captain_assistant, account: create(:account))
      data = payload.merge('assistants' => payload['assistants'] + [{ 'id' => other.id, 'routing_description' => 'x', 'description' => 'y' }])

      expect_refused(write_json(data), /not agents of account 990043: #{other.id} \(account #{other.account_id}\)/, apply: false)
      expect_refused(write_json(data), /not agents of account 990043: #{other.id} \(account #{other.account_id}\)/)
    end

    it 'refuses an agent that does not exist and an account that does not exist' do
      expect_refused(write_json(payload.merge('assistants' => [payload['assistants'].first.merge('id' => 999_999_999)])),
                     /not agents of account 990043: 999999999 \(does not exist\)/)
      expect_refused(write_json(payload.merge('account_id' => 999_999_999)), 'account 999999999 does not exist')
    end

    it 'refuses a field without a home in the database' do
      data = payload.merge('assistants' => [payload['assistants'].first.merge('tools' => ['create_appointment'])])

      expect_refused(write_json(data), /assistants\[0\] must have exactly the keys id, routing_description, description .*unknown: tools/)
      expect_refused(write_json(payload.merge('notes' => 'x')), /unknown: notes/)
    end

    it 'refuses a clinic block with a tool link, after printing the lengths' do
      expect_refused(write_json(payload.merge('shared_block' => 'Запись: [@Запись](tool://create_appointment).')),
                     /account 990043: Контекст клиники не может ссылаться на инструменты и навыки/)
      expect(printed).to include('~ clinic block: 0 -> ')
    end

    it 'refuses a prompt the agent would not save' do
      data = payload.merge('assistants' => [payload['assistants'].first, payload['assistants'].last.merge('description' => 'я' * 20_001)])

      expect_refused(write_json(data), /assistant 990109: .*20000/)
    end

    it 'refuses an agent whose save would change more than the prompt and the card' do
      gynecology.update_columns(config: gynecology.config.merge('rules' => [{ 'content' => 'Старое правило.', 'enabled' => true }])) # rubocop:disable Rails/SkipsModelValidations

      expect_refused(fixture_path, /assistant 990077: its save would change more than the prompt and the card \(description \(legacy rules .*config/)
    end
  end

  describe 'the rake task' do
    let(:task) { Rake::Task['onelink:captain:apply_prompt_pack'] }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:captain:apply_prompt_pack')
      task.reenable
    end

    def invoke(env)
      with_modified_env({ 'FILE' => nil, 'RESTORE' => nil, 'APPLY' => nil, 'VERBOSE' => nil, 'BACKUP_DIR' => backup_dir }.merge(env)) do
        task.invoke
      end
    end

    it 'makes a dry run by default' do
      expect { invoke('FILE' => fixture_path) }.to output(/dry run, nothing is written.*Would write: clinic block changed/m).to_stdout
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'writes with APPLY=1 into BACKUP_DIR and rolls back with RESTORE', :aggregate_failures do
      expect { invoke('FILE' => fixture_path, 'APPLY' => '1') }.to output(/Written: clinic block changed/).to_stdout
      expect(ultrasound.reload.description).to eq(payload['assistants'].last['description'])

      task.reenable
      expect { invoke('RESTORE' => backups.sole, 'APPLY' => '1') }.to output(/Written: clinic block changed/).to_stdout
      expect(ultrasound.reload.description).to eq('Старый промпт УЗИ.')
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'stops with a message and writes nothing when it refuses', :aggregate_failures do
      other = create(:captain_assistant, account: create(:account))
      path = write_json(payload.merge('assistants' => [payload['assistants'].first.merge('id' => other.id)]))

      expect { expect { invoke('FILE' => path, 'APPLY' => '1') }.to raise_error(SystemExit) }
        .to output(/REFUSED, nothing was written:\nnot agents of account 990043: #{other.id}/).to_stderr
      expect(backups).to be_empty
    end

    it 'takes exactly one of FILE and RESTORE, and only 1 or 0 for APPLY and VERBOSE', :aggregate_failures do
      expect { expect { invoke({}) }.to raise_error(SystemExit) }.to output(/pass exactly one of FILE/).to_stderr
      task.reenable
      expect { expect { invoke('FILE' => fixture_path, 'RESTORE' => fixture_path) }.to raise_error(SystemExit) }
        .to output(/pass exactly one of FILE/).to_stderr
      task.reenable
      expect { expect { invoke('FILE' => fixture_path, 'APPLY' => 'yes') }.to raise_error(SystemExit) }
        .to output(/REFUSED: APPLY must be 1 or 0, not "yes"/).to_stderr
      expect(account.reload.captain_clinic_context).to eq('')
    end
  end
end
