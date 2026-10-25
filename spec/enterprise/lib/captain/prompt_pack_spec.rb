# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

# rake onelink:captain:apply_prompt_pack FILE=<prompts-v2 pack> [VERBOSE=1] [APPLY=1 CONFIRM=<digest>] | RESTORE=<backup> [...]: the
# clinic block and the prompt and card of the listed agents of one clinic, with a backup first and a way back, writing only the
# change of the reviewed dry run. The fixture names account 990043 and its agents 990077 and 990109.
RSpec.describe Captain::PromptPack do
  let(:fixture_path) { Rails.root.join('spec/fixtures/files/prompts_v2/clinic_990043.json').to_s }
  let(:fixture_sha256) { Digest::SHA256.file(fixture_path).hexdigest }
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

  # The builds these examples run on have the decision router unless an example says otherwise
  before { allow(described_class).to receive(:router_live?).and_return(true) }

  after do
    tempfiles.each(&:unlink)
    FileUtils.remove_entry(backup_dir)
  end

  # Every run of an example prints into the same out
  def pack(verbose: false)
    described_class.new(out: out, backup_dir: backup_dir, verbose: verbose)
  end

  def printed
    out.string
  end

  # The digest that a dry run prints for a pack (or a backup, restore: true) as the database stands; nil when nothing would change
  def digest_of(path = fixture_path, restore: false)
    dry_out = StringIO.new
    dry = described_class.new(out: dry_out, backup_dir: backup_dir)
    restore ? dry.restore(path) : dry.apply_file(path)
    dry_out.string[/To write exactly this: APPLY=1 CONFIRM=(\h{16})$/, 1]
  end

  # A dry run, then the apply of what it showed
  def apply(path = fixture_path)
    pack.apply_file(path, apply: true, confirm: digest_of(path))
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

  describe 'a dry run' do
    it 'prints the sha256 of the file, what changes with the lengths in characters and the digest, no texts, and writes nothing',
       :aggregate_failures do
      before = snapshot

      expect(pack.apply_file(fixture_path)).to be_nil

      expect(snapshot).to eq(before)
      expect(backups).to be_empty
      context_length = payload['shared_block'].strip.length
      prompt_length = payload['assistants'].first['description'].length
      card_length = payload['assistants'].first['routing_description'].length
      expect(printed).to start_with(
        "Prompt texts of account 990043 «МО Тест» from the pack #{fixture_path} (sha256 #{fixture_sha256}): dry run, nothing is written.\n"
      )
      expect(printed).to include(
        "~ clinic block: 0 -> #{context_length} chars\n",
        "~ assistant 990077 «Гинекология» prompt (description): 26 -> #{prompt_length} chars\n",
        "~ assistant 990077 «Гинекология» card (routing_description): 29 -> #{card_length} chars\n",
        '~ assistant 990109 «УЗИ» card (routing_description): 0 -> '
      )
      digest = printed[/CONFIRM=(\h{16})\n\z/, 1]
      expect(printed).to end_with("Would write: clinic block changed; agents changed: 990077, 990109 (listed: 990077, 990109).\n" \
                                  "Digest of this change: #{digest}. To write exactly this: APPLY=1 CONFIRM=#{digest}\n")
      expect(printed).not_to include('Клиника:', 'Направление:', 'Жалобы', '---', '+++', 'decision router')
    end

    it 'adds a unified diff of every changed text with VERBOSE' do
      pack(verbose: true).apply_file(fixture_path)

      expect(printed).to include("--- clinic block (stored)\n+++ clinic block (wanted)\n@@ -0,0 +1,9 @@\n+Клиника:\n",
                                 "-Старый промпт гинекологии.\n+Направление:\n")
    end

    it 'gives the same digest for the same file and stored texts, and another one when either changes', :aggregate_failures do
      digest = digest_of

      expect(digest_of).to eq(digest)

      edited_pack = write_json(payload.merge('assistants' => [payload['assistants'].first,
                                                              payload['assistants'].last.merge('routing_description' => 'УЗИ.')]))
      expect(digest_of(edited_pack)).not_to eq(digest)

      ultrasound.update_columns(description: 'Промпт УЗИ, изменённый после проверки.') # rubocop:disable Rails/SkipsModelValidations
      expect(digest_of).not_to eq(digest)
    end

    it 'says when nothing would change, with no digest', :aggregate_failures do
      apply
      out.truncate(0)
      out.rewind

      pack.apply_file(fixture_path)

      expect(printed).to include("= clinic block: unchanged, #{payload['shared_block'].strip.length} chars\n",
                                 '= assistant 990109 «УЗИ» card (routing_description): unchanged, ')
      expect(printed).to end_with('Nothing to write, every text is stored already (clinic block unchanged; agents changed: none ' \
                                  "(listed: 990077, 990109)).\n")
      expect(printed).not_to include('Digest', 'CONFIRM')
    end

    it 'says that a build without the decision router refuses APPLY=1 of the pack' do
      allow(described_class).to receive(:router_live?).and_return(false)

      pack.apply_file(fixture_path)

      expect(printed).to end_with("This build has no decision router (Captain::Runtime::DecisionRouter), so it refuses APPLY=1 of a pack.\n")
    end
  end

  describe 'apply' do
    it 'backs the stored texts up, then writes the clinic block and the prompt and card of every listed agent', :aggregate_failures do
      backup = apply

      expect(backups).to eq([backup])
      expect(File.basename(backup)).to match(/\Aprompt_pack_backup_990043_\d{8}-\d{6}-\d{3}\.json\z/)
      expect(File.stat(backup).mode & 0o777).to eq(0o600)
      expect(JSON.parse(File.read(backup))).to include(
        'kind' => 'onelink_prompt_pack_backup', 'version' => 1, 'account_id' => 990_043,
        'source' => "pack #{fixture_path} (sha256 #{fixture_sha256})", 'clinic_context' => '',
        'assistants' => [
          { 'id' => 990_077, 'description' => 'Старый промпт гинекологии.', 'routing_description' => 'Главный агент: всё остальное.' },
          { 'id' => 990_109, 'description' => 'Старый промпт УЗИ.', 'routing_description' => nil }
        ]
      )
      expect(account.reload.captain_clinic_context).to eq(payload['shared_block'].strip)
      payload['assistants'].each do |entry|
        expect(Captain::Assistant.find(entry['id'])).to have_attributes(entry.slice('description', 'routing_description'))
      end
      expect(printed).to include('writing in one transaction')
      expect(printed).to end_with("Written: clinic block changed; agents changed: 990077, 990109 (listed: 990077, 990109).\n" \
                                  "Backup of the stored texts: #{backup}\n" \
                                  "Roll back with: RESTORE=#{backup} (a dry run), then the same with APPLY=1 CONFIRM=<the digest it prints>\n")
    end

    it 'touches nothing else: no unlisted agent, no other attribute of an agent or of the account', :aggregate_failures do
      unlisted_before = unlisted.reload.attributes
      ultrasound_before = ultrasound.reload.attributes.except('description', 'routing_description', 'updated_at')

      apply

      expect(unlisted.reload.attributes).to eq(unlisted_before)
      expect(ultrasound.reload.attributes.except('description', 'routing_description', 'updated_at')).to eq(ultrasound_before)
      account.reload
      expect(account.internal_attributes).to eq('medelement_note' => 'keep', 'captain_clinic_context' => payload['shared_block'].strip)
      expect(account.settings).to eq({})
    end

    it 'adds the entry that a save of the account would add to its audit log, naming this task', :aggregate_failures do
      expect { apply }.to change { account.audits.count }.by(1)

      expect(account.audits.last).to have_attributes(
        action: 'update', username: 'rake onelink:captain:apply_prompt_pack', comment: 'system', user_id: nil,
        audited_changes: { 'internal_attributes' => [{ 'medelement_note' => 'keep' },
                                                     { 'medelement_note' => 'keep', 'captain_clinic_context' => payload['shared_block'].strip }] }
      )
    end

    it 'adds no audit entry to the account when the clinic block is stored already' do
      account.update_columns(internal_attributes: { 'medelement_note' => 'keep', 'captain_clinic_context' => payload['shared_block'].strip }) # rubocop:disable Rails/SkipsModelValidations

      expect { apply }.not_to(change { account.audits.count })
      expect(printed).to include('Written: clinic block unchanged; agents changed: 990077, 990109')
    end

    it 'is idempotent: a second run, even with the same digest, writes nothing and makes no backup', :aggregate_failures do
      digest = digest_of
      pack.apply_file(fixture_path, apply: true, confirm: digest)
      state = snapshot

      expect(pack.apply_file(fixture_path, apply: true, confirm: digest)).to be_nil

      expect(snapshot).to eq(state)
      expect(backups.size).to eq(1)
      expect(printed).to include('= clinic block: unchanged', '= assistant 990109 «УЗИ» card (routing_description): unchanged',
                                 'Nothing written, every text is stored already (clinic block unchanged; agents changed: none')
    end

    it 'writes only what differs' do
      gynecology.update!(payload['assistants'].first.slice('description', 'routing_description'))
      gynecology_updated_at = gynecology.reload.updated_at

      apply

      expect(gynecology.reload.updated_at).to eq(gynecology_updated_at)
      expect(printed).to include('agents changed: 990109 (listed: 990077, 990109)')
    end

    it 'writes nothing at all when a later write fails: one transaction, and it claims no write', :aggregate_failures do
      digest = digest_of
      before = snapshot
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(Captain::Assistant).to receive(:save!).and_wrap_original do |method, *args|
        raise ActiveRecord::RecordNotSaved, 'disk full' if method.receiver.id == ultrasound.id

        method.call(*args)
      end
      # rubocop:enable RSpec/AnyInstance

      expect { pack.apply_file(fixture_path, apply: true, confirm: digest) }
        .to raise_error(ActiveRecord::RecordNotSaved).and(not_change { account.audits.count })
      expect(snapshot).to eq(before)
      expect(printed).not_to include('Written:', 'Backup of the stored texts')
    end

    it 'prints what was written only after the transaction has returned' do
      digest = digest_of
      written_when_returned = []
      allow(ActiveRecord::Base).to receive(:transaction).and_wrap_original do |method, *args, **options, &block|
        method.call(*args, **options, &block).tap { written_when_returned << printed.include?('Written:') }
      end

      pack.apply_file(fixture_path, apply: true, confirm: digest)

      expect(written_when_returned.last).to be(false)
      expect(printed).to include('Written: clinic block changed')
    end

    it 'writes nothing when the backup cannot be written' do
      digest = digest_of
      file_in_the_way = File.join(backup_dir, 'not-a-directory')
      File.write(file_in_the_way, 'x')
      before = snapshot

      expect { described_class.new(out: StringIO.new, backup_dir: file_in_the_way).apply_file(fixture_path, apply: true, confirm: digest) }
        .to raise_error(SystemCallError)
      expect(snapshot).to eq(before)
    end
  end

  describe 'the digest that APPLY=1 needs' do
    def expect_refused_apply(path, confirm, message)
      before = snapshot

      expect { pack.apply_file(path, apply: true, confirm: confirm) }.to raise_error(described_class::Refused, message)
      expect(snapshot).to eq(before)
      expect(backups).to be_empty
    end

    it 'refuses an apply without one, before it reads the database' do
      allow(Account).to receive(:find_by).and_call_original

      expect_refused_apply(fixture_path, nil, /APPLY=1 needs CONFIRM=<the digest that the dry run printed>/)
      expect_refused_apply(fixture_path, '  ', /APPLY=1 needs CONFIRM/)
      expect(Account).not_to have_received(:find_by)
    end

    it 'refuses the digest of a dry run when a stored text changed after it' do
      digest = digest_of
      ultrasound.update_columns(description: 'Промпт УЗИ, изменённый после проверки.') # rubocop:disable Rails/SkipsModelValidations

      expect_refused_apply(fixture_path, digest, /CONFIRM=#{digest} is not the digest of this change: the file or a stored text changed/)
      expect(ultrasound.reload.description).to eq('Промпт УЗИ, изменённый после проверки.')
    end

    it 'refuses the digest of a dry run when the file changed after it' do
      path = write_json(payload)
      digest = digest_of(path)
      File.write(path, JSON.generate(payload.merge('shared_block' => "#{payload['shared_block']}\nПарковка: бесплатно.")))

      expect_refused_apply(path, digest, /is not the digest of this change/)
    end

    it 'refuses a made-up digest' do
      expect_refused_apply(fixture_path, '0123456789abcdef', /CONFIRM=0123456789abcdef is not the digest of this change/)
    end
  end

  describe 'the decision router' do
    it 'is live when its class can be loaded' do
      allow(described_class).to receive(:router_live?).and_call_original

      stub_const('Captain::PromptPack::ROUTER_CLASS', 'Captain::PromptPack')
      expect(described_class.router_live?).to be(true)
      stub_const('Captain::PromptPack::ROUTER_CLASS', 'Captain::Runtime::NoSuchRouter')
      expect(described_class.router_live?).to be(false)
    end

    it 'refuses to apply a pack on a build without it, before it reads the database', :aggregate_failures do
      digest = digest_of
      allow(described_class).to receive(:router_live?).and_return(false)
      before = snapshot

      expect { pack.apply_file(fixture_path, apply: true, confirm: digest) }
        .to raise_error(described_class::Refused, /this build has no decision router \(Captain::Runtime::DecisionRouter\)/)
      expect(snapshot).to eq(before)
      expect(backups).to be_empty
      expect(printed).to be_empty
    end
  end

  describe 'restore' do
    let!(:backup) { apply }

    it 'makes a dry run by default' do
      state = snapshot

      pack.restore(backup)

      expect(snapshot).to eq(state)
      expect(printed).to include("from the backup #{backup} (sha256 #{Digest::SHA256.file(backup).hexdigest}, taken at ",
                                 'dry run, nothing is written', "~ clinic block: #{payload['shared_block'].strip.length} -> 0 chars",
                                 'To write exactly this: APPLY=1 CONFIRM=')
    end

    it 'writes the stored texts back, backing the current ones up first', :aggregate_failures do
      second_backup = pack.restore(backup, apply: true, confirm: digest_of(backup, restore: true))

      expect(account.reload.internal_attributes).to eq('medelement_note' => 'keep')
      expect(gynecology.reload).to have_attributes(description: 'Старый промпт гинекологии.',
                                                   routing_description: 'Главный агент: всё остальное.')
      expect(ultrasound.reload).to have_attributes(description: 'Старый промпт УЗИ.', routing_description: nil)
      expect(backups).to contain_exactly(backup, second_backup)
      expect(JSON.parse(File.read(second_backup))['clinic_context']).to eq(payload['shared_block'].strip)
      expect(account.audits.last.audited_changes['internal_attributes'].last).to eq('medelement_note' => 'keep')
      expect(pack.restore(backup, apply: true, confirm: 'anything')).to be_nil
    end

    it 'needs the digest of its dry run too' do
      expect { pack.restore(backup, apply: true) }.to raise_error(described_class::Refused, /APPLY=1 needs CONFIRM/)
      expect { pack.restore(backup, apply: true, confirm: '0123456789abcdef') }.to raise_error(described_class::Refused, /is not the digest/)
    end

    it 'works on a build without the decision router' do
      allow(described_class).to receive(:router_live?).and_return(false)

      pack.restore(backup, apply: true, confirm: digest_of(backup, restore: true))

      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'refuses a backup whose agent was moved to another account or deleted, and writes nothing', :aggregate_failures do
      other_account = create(:account)
      ultrasound.update_columns(account_id: other_account.id) # rubocop:disable Rails/SkipsModelValidations
      state = snapshot

      expect { pack.restore(backup, apply: true, confirm: 'unchecked') }
        .to raise_error(described_class::Refused, "not agents of account 990043: 990109 (account #{other_account.id})")

      Captain::Assistant.where(id: ultrasound.id).delete_all
      expect { pack.restore(backup) }.to raise_error(described_class::Refused, 'not agents of account 990043: 990109 (does not exist)')
      expect(snapshot).to eq(state)
      expect(backups).to eq([backup])
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
    # Every refusal here comes before the digest is compared, so any digest will do
    def expect_refused(path, message, apply: true)
      before = snapshot

      expect { pack.apply_file(path, apply: apply, confirm: 'unchecked') }.to raise_error(described_class::Refused, message)
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

    it 'refuses an agent whose save would merge its legacy rules into the prompt' do
      gynecology.update_columns(config: gynecology.config.merge('rules' => [{ 'content' => 'Старое правило.', 'enabled' => true }])) # rubocop:disable Rails/SkipsModelValidations

      expect_refused(fixture_path, /assistant 990077: its save would change more than the prompt and the card \(description \(legacy rules .*config/)
    end

    it 'refuses an agent whose save would merge its legacy response guidelines and guardrails into the prompt' do
      gynecology.update_columns(response_guidelines: ['Отвечай вежливо.'], guardrails: ['Не ставь диагнозы.']) # rubocop:disable Rails/SkipsModelValidations

      expect_refused(fixture_path, /assistant 990077: its save would change more than the prompt and the card #{Regexp.escape(
        '(description (legacy rules appended to the prompt)'
      )}(?=.*response_guidelines)(?=.*guardrails)/)
    end

    it 'refuses an agent whose save would drop its legacy settings' do
      legacy = { 'instructions' => 'Старые инструкции.', 'copilot_instructions' => 'Старые подсказки.', 'feature_contact_attributes' => true }
      gynecology.update_columns(config: gynecology.config.merge(legacy)) # rubocop:disable Rails/SkipsModelValidations

      expect_refused(fixture_path, /assistant 990077: its save would change more than the prompt and the card \(config\)/)
    end
  end

  describe 'the rake task' do
    let(:task) { Rake::Task['onelink:captain:apply_prompt_pack'] }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:captain:apply_prompt_pack')
      task.reenable
    end

    def invoke(env)
      env = { 'FILE' => nil, 'RESTORE' => nil, 'APPLY' => nil, 'CONFIRM' => nil, 'VERBOSE' => nil, 'BACKUP_DIR' => backup_dir }.merge(env)
      with_modified_env(env) do
        task.reenable
        task.invoke
      end
    end

    # What the task prints to stdout
    def invoke_printing(env)
      stdout = $stdout
      $stdout = StringIO.new
      invoke(env)
      $stdout.string
    ensure
      $stdout = stdout
    end

    it 'makes a dry run by default' do
      expect { invoke('FILE' => fixture_path) }
        .to output(/dry run, nothing is written.*Would write: clinic block changed.*To write exactly this: APPLY=1 CONFIRM=\h{16}/m).to_stdout
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'writes with APPLY=1 and the CONFIRM digest into BACKUP_DIR, and rolls back with RESTORE the same way', :aggregate_failures do
      digest = invoke_printing('FILE' => fixture_path)[/CONFIRM=(\h{16})/, 1]
      expect { invoke('FILE' => fixture_path, 'APPLY' => '1', 'CONFIRM' => digest) }.to output(/Written: clinic block changed/).to_stdout
      expect(ultrasound.reload.description).to eq(payload['assistants'].last['description'])

      restore_digest = invoke_printing('RESTORE' => backups.sole)[/CONFIRM=(\h{16})/, 1]
      expect { invoke('RESTORE' => backups.sole, 'APPLY' => '1', 'CONFIRM' => restore_digest) }
        .to output(/Written: clinic block changed/).to_stdout
      expect(ultrasound.reload.description).to eq('Старый промпт УЗИ.')
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'stops with a message and writes nothing when it refuses', :aggregate_failures do
      expect { expect { invoke('FILE' => fixture_path, 'APPLY' => '1') }.to raise_error(SystemExit) }
        .to output(/REFUSED, nothing was written:\nAPPLY=1 needs CONFIRM=/).to_stderr
      expect { expect { invoke('FILE' => fixture_path, 'APPLY' => '1', 'CONFIRM' => '0123456789abcdef') }.to raise_error(SystemExit) }
        .to output(/REFUSED, nothing was written:\nCONFIRM=0123456789abcdef is not the digest of this change/).to_stderr

      other = create(:captain_assistant, account: create(:account))
      path = write_json(payload.merge('assistants' => [payload['assistants'].first.merge('id' => other.id)]))
      expect { expect { invoke('FILE' => path, 'APPLY' => '1', 'CONFIRM' => 'unchecked') }.to raise_error(SystemExit) }
        .to output(/REFUSED, nothing was written:\nnot agents of account 990043: #{other.id}/).to_stderr
      expect(backups).to be_empty
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'takes exactly one of FILE and RESTORE, and only 1 or 0 for APPLY and VERBOSE', :aggregate_failures do
      expect { expect { invoke({}) }.to raise_error(SystemExit) }.to output(/pass exactly one of FILE/).to_stderr
      expect { expect { invoke('FILE' => fixture_path, 'RESTORE' => fixture_path) }.to raise_error(SystemExit) }
        .to output(/pass exactly one of FILE/).to_stderr
      expect { expect { invoke('FILE' => fixture_path, 'APPLY' => 'yes') }.to raise_error(SystemExit) }
        .to output(/REFUSED: APPLY must be 1 or 0, not "yes"/).to_stderr
      expect(account.reload.captain_clinic_context).to eq('')
    end
  end
end
