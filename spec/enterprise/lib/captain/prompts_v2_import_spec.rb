# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# rake onelink:captain:apply_prompts_v2[json_path,apply]: the clinic context and the prompts and cards of the listed agents of one
# clinic, from a JSON file. The fixture names account 990043 and its agents 990077 and 990109.
RSpec.describe Captain::PromptsV2Import do
  let(:fixture_path) { Rails.root.join('spec/fixtures/files/prompts_v2/clinic_990043.json').to_s }
  let(:payload) { JSON.parse(File.read(fixture_path)) }
  let!(:account) { create(:account, id: 990_043, name: 'МО Тест') }
  let!(:gynecology) do
    create(:captain_assistant, id: 990_077, account: account, name: 'Гинекология',
                               description: "Ты главный ИИ-администратор.\n\nУслуги и цены:\n- Приём акушера-гинеколога — 10 000 ₸",
                               routing_description: 'Главный агент: всё остальное.')
  end
  let!(:ultrasound) do
    create(:captain_assistant, id: 990_109, account: account, name: 'УЗИ', description: 'Старый промпт УЗИ.', routing_description: 'УЗИ.')
  end
  let!(:unlisted) { create(:captain_assistant, account: account, name: 'Жалобы', description: 'Жалобы.', routing_description: 'Жалобы.') }
  let(:tempfiles) { [] }

  def run(path = fixture_path, apply: false)
    output = StringIO.new
    described_class.new(path: path, out: output).call(apply: apply)
    output.string
  end

  def write_json(data)
    file = Tempfile.new(['prompts_v2', '.json'])
    file.write(data.is_a?(String) ? data : JSON.generate(data))
    file.close
    tempfiles << file
    file.path
  end

  def snapshot
    [account.reload.internal_attributes, Captain::Assistant.where(account_id: account.id).order(:id).pluck(:id, :description, :routing_description)]
  end

  after { tempfiles.each(&:unlink) }

  describe 'a dry run' do
    it 'prints a unified diff of the clinic context and of the prompt and the card of every listed agent, and writes nothing' do
      before = snapshot

      output = run

      expect(snapshot).to eq(before)
      expect(output).to start_with('Prompts v2 for account 990043 «МО Тест»')
      expect(output).to include('dry run, nothing is written (pass apply=true to write)')
      expect(output).to include(
        "--- clinic context (stored)\n+++ clinic context (file)\n@@ -0,0 +1,9 @@\n+Клиника:\n+- МО «Тест», г. Актобе. Сайт: example.kz.\n"
      )
      expect(output).to include(
        "--- assistant 990077 «Гинекология» description (stored)\n+++ assistant 990077 «Гинекология» description (file)\n",
        "-Ты главный ИИ-администратор.\n+Направление:\n",
        " Услуги и цены:\n - Приём акушера-гинеколога — 10 000 ₸\n",
        "--- assistant 990077 «Гинекология» routing_description (stored)\n",
        "-Главный агент: всё остальное.\n+Гинекология и врачи: цены, подготовка и запись на приём.\n",
        "--- assistant 990109 «УЗИ» description (stored)\n",
        "--- assistant 990109 «УЗИ» routing_description (stored)\n"
      )
      expect(output).to end_with("Would write: clinic context changed; agents changed: 990077, 990109 (listed: 990077, 990109).\n")
      expect(output).not_to include('Жалобы', "assistant #{unlisted.id} ")
    end

    it 'says what is unchanged' do
      run(apply: true)

      output = run

      expect(output).to include('= clinic context: unchanged', '= assistant 990077 «Гинекология» description: unchanged',
                                '= assistant 990109 «УЗИ» routing_description: unchanged')
      expect(output).to end_with("Would write: clinic context unchanged; agents changed: none (listed: 990077, 990109).\n")
    end
  end

  describe 'apply' do
    it 'writes the clinic context and every listed agent, and never an agent the file does not list' do
      unlisted_before = unlisted.reload.attributes

      output = run(apply: true)

      expect(output).to include('writing in one transaction')
      expect(output).to end_with("Written: clinic context changed; agents changed: 990077, 990109 (listed: 990077, 990109).\n")
      expect(account.reload.captain_clinic_context).to eq(payload['shared_block'].strip)
      expect(account.internal_attributes['captain_clinic_context']).to eq(payload['shared_block'].strip)
      payload['assistants'].each do |entry|
        expect(Captain::Assistant.find(entry['id'])).to have_attributes(
          description: entry['description'], routing_description: entry['routing_description']
        )
      end
      expect(unlisted.reload.attributes).to eq(unlisted_before)
    end

    it 'writes nothing at all when a later write fails: one transaction' do
      before = snapshot
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(Captain::Assistant).to receive(:save!).and_wrap_original do |method, *args|
        raise ActiveRecord::RecordNotSaved, 'disk full' if method.receiver.id == ultrasound.id

        method.call(*args)
      end
      # rubocop:enable RSpec/AnyInstance

      expect { run(apply: true) }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(snapshot).to eq(before)
    end
  end

  describe 'what it refuses, with nothing written' do
    def expect_refused(path, message, apply: true)
      before = snapshot

      expect { run(path, apply: apply) }.to raise_error(described_class::Refused, message)
      expect(snapshot).to eq(before)
    end

    it 'refuses an agent of another account and names its account' do
      other = create(:captain_assistant, account: create(:account))
      data = payload.merge('assistants' => payload['assistants'] + [{ 'id' => other.id, 'routing_description' => 'x', 'description' => 'y' }])

      expect_refused(write_json(data), /not agents of account 990043: #{other.id} \(account #{other.account_id}\)/)
    end

    it 'refuses an agent that does not exist' do
      data = payload.merge('assistants' => [payload['assistants'].first.merge('id' => 999_999_999)])

      expect_refused(write_json(data), /not agents of account 990043: 999999999 \(does not exist\)/)
    end

    it 'refuses an account that does not exist' do
      expect_refused(write_json(payload.merge('account_id' => 999_999_999)), 'account 999999999 does not exist')
    end

    it 'refuses a file of another shape' do
      first = payload['assistants'].first
      {
        '{ not json' => /not valid JSON/,
        '[]' => /one JSON object/,
        JSON.generate(payload.except('shared_block')) => /exactly the keys account_id, shared_block, assistants \(missing: shared_block; unknown/,
        JSON.generate(payload.merge('extra' => 1)) => /unknown: extra/,
        JSON.generate(payload.merge('account_id' => '990043')) => /account_id must be a positive integer/,
        JSON.generate(payload.merge('shared_block' => '  ')) => /shared_block must be a non-empty string/,
        JSON.generate(payload.merge('assistants' => [])) => /assistants must be a non-empty list/,
        JSON.generate(payload.merge('assistants' => [first.except('description')])) => /assistants\[0\] must have exactly the keys/,
        JSON.generate(payload.merge('assistants' => [first.merge('id' => 1.5)])) => /assistants\[0\].id must be a positive integer/,
        JSON.generate(payload.merge('assistants' => [first.merge('routing_description' => '')])) =>
          /assistants\[0\].routing_description must be a non-empty string/,
        JSON.generate(payload.merge('assistants' => [first, first])) => /lists an id more than once: 990077/
      }.each { |content, message| expect_refused(write_json(content), message) }
    end

    it 'refuses a missing path or file' do
      expect_refused('', 'json_path is required')
      expect_refused('/nonexistent/prompts.json', 'file not found: /nonexistent/prompts.json')
    end

    it 'refuses a clinic context with a tool link, after printing the diff, even on a dry run' do
      data = payload.merge('shared_block' => 'Запись: [@Запись](tool://create_appointment).')

      expect_refused(write_json(data), /account 990043: Контекст клиники не может ссылаться на инструменты и навыки/, apply: false)
      expect_refused(write_json(data), /Контекст клиники не может ссылаться/)
    end

    it 'refuses a prompt the agent would not save, and writes neither the clinic context nor the other agents' do
      data = payload.merge('assistants' => [payload['assistants'].first, payload['assistants'].last.merge('description' => 'я' * 20_001)])

      expect_refused(write_json(data), /assistant 990109: .*20000/)
    end

    it 'refuses a prompt that the save of the agent would change by merging its legacy rules' do
      gynecology.update_columns(config: gynecology.config.merge('rules' => [{ 'content' => 'Старое правило.', 'enabled' => true }])) # rubocop:disable Rails/SkipsModelValidations

      expect_refused(fixture_path, /assistant 990077: its save would add legacy rules/)
    end
  end

  describe 'the rake task' do
    let(:task) { Rake::Task['onelink:captain:apply_prompts_v2'] }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:captain:apply_prompts_v2')
      task.reenable
    end

    it 'makes a dry run by default' do
      expect { task.invoke(fixture_path) }.to output(/dry run, nothing is written.*Would write: clinic context changed/m).to_stdout
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'writes with apply=true' do
      expect { task.invoke(fixture_path, 'true') }.to output(/Written: clinic context changed/).to_stdout
      expect(account.reload.captain_clinic_context).to eq(payload['shared_block'].strip)
      expect(ultrasound.reload.description).to eq(payload['assistants'].last['description'])
    end

    it 'stops with a message and writes nothing when it refuses' do
      path = write_json(payload.merge('account_id' => 999_999_999))

      expect { expect { task.invoke(path, 'true') }.to raise_error(SystemExit) }
        .to output(/REFUSED, nothing was written:\naccount 999999999 does not exist/).to_stderr
    end

    it 'takes only true or false for apply' do
      expect { expect { task.invoke(fixture_path, 'yes') }.to raise_error(SystemExit) }
        .to output(/REFUSED: apply must be true or false, not "yes"/).to_stderr
      expect(account.reload.captain_clinic_context).to eq('')
    end
  end
end
