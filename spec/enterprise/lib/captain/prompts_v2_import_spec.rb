# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The reader of a prompts-v2 pack file (Captain::PromptPack applies it), and the replaced rake onelink:captain:apply_prompts_v2.
# The fixture names account 990043 and its agents 990077 and 990109.
RSpec.describe Captain::PromptsV2Import do
  let(:fixture_path) { Rails.root.join('spec/fixtures/files/prompts_v2/clinic_990043.json').to_s }
  let(:payload) { JSON.parse(File.read(fixture_path)) }
  let(:tempfiles) { [] }

  def write_json(data)
    file = Tempfile.new(['prompts_v2', '.json'])
    file.write(data.is_a?(String) ? data : JSON.generate(data))
    file.close
    tempfiles << file
    file.path
  end

  after { tempfiles.each(&:unlink) }

  it 'reads the file as a hash with string keys and the sha256 of its bytes' do
    file = described_class.new(path: fixture_path)

    expect(file.payload).to eq(payload)
    expect(file.sha256).to eq(Digest::SHA256.file(fixture_path).hexdigest)
  end

  it 'reads a file with a byte order mark, and the sha256 is of the bytes as they are' do
    bytes = "\u{FEFF}#{File.read(fixture_path)}"
    file = described_class.new(path: write_json(bytes))

    expect(file.payload).to eq(payload)
    expect(file.sha256).to eq(Digest::SHA256.hexdigest(bytes))
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
      JSON.generate(payload.merge('assistants' => ['x'])) => /assistants\[0\] must be an object/,
      JSON.generate(payload.merge('assistants' => [first.except('description')])) => /assistants\[0\] must have exactly the keys/,
      JSON.generate(payload.merge('assistants' => [first.merge('id' => 1.5)])) => /assistants\[0\].id must be a positive integer/,
      JSON.generate(payload.merge('assistants' => [first.merge('routing_description' => '')])) =>
        /assistants\[0\].routing_description must be a non-empty string/,
      JSON.generate(payload.merge('assistants' => [first, first])) => /lists an id more than once: 990077/
    }.each do |content, message|
      file = described_class.new(path: write_json(content))
      expect { file.payload }.to raise_error(described_class::Refused, message)
      expect { file.sha256 }.to raise_error(described_class::Refused, message)
    end
  end

  it 'refuses a missing path or file' do
    expect { described_class.new(path: '').payload }.to raise_error(described_class::Refused, 'a pack file is required')
    expect { described_class.new(path: '/nonexistent/prompts.json').payload }
      .to raise_error(described_class::Refused, 'file not found: /nonexistent/prompts.json')
  end

  describe 'the replaced rake task onelink:captain:apply_prompts_v2' do
    let(:task) { Rake::Task['onelink:captain:apply_prompts_v2'] }
    let!(:account) { create(:account, id: 990_043, name: 'МО Тест') }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:captain:apply_prompts_v2')
      task.reenable
    end

    it 'writes nothing, even with apply=true, and prints the command that replaces it', :aggregate_failures do
      command = "replaced by onelink:captain:apply_prompt_pack.\nDry run: rake onelink:captain:apply_prompt_pack FILE=#{fixture_path}\n"
      expect { expect { task.invoke(fixture_path, 'true') }.to raise_error(SystemExit) }
        .to output(a_string_including(command, 'the same with APPLY=1 CONFIRM=')).to_stderr
      expect(account.reload.captain_clinic_context).to eq('')
    end
  end
end
