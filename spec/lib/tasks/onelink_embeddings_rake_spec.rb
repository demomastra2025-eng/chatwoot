require 'rails_helper'
require 'rake'

# The commands of the data step that moves the platform to one embedding model. The embedding model is a fake; the database is real.
# All data is synthetic.
RSpec.describe 'onelink:embeddings' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:backup_dir) { Rails.root.join('tmp', "embedding-rake-spec-#{SecureRandom.hex(4)}").to_s }
  let(:embedder) { instance_double(Captain::Llm::EmbeddingService) }
  let!(:faq) { create(:captain_assistant_response, account: account, assistant: assistant, question: 'Где вы?', answer: 'Абая 1') }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:embeddings:status')
    %w[status preview apply restore].each { |name| Rake::Task["onelink:embeddings:#{name}"].reenable }
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-key')
    upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'text-embedding-3-large')
    faq.update_columns(embedding_model: 'text-embedding-3-large') # rubocop:disable Rails/SkipsModelValidations
    allow(embedder).to receive(:get_embeddings) { |texts, **| texts.map { unit_vector(7) } }
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedder)
  end

  after { FileUtils.rm_rf(backup_dir) }

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def run(name, **env)
    with_modified_env(env.transform_keys(&:to_s)) { Rake::Task["onelink:embeddings:#{name}"].invoke }
  end

  it 'shows the model in force and which model made the vectors of each table' do
    expect { run(:status) }
      .to output(/CAPTAIN_EMBEDDING_MODEL: text-embedding-3-large.*faq\s+rows\s+1\s+text-embedding-3-large: 1/m).to_stdout
  end

  it 'previews the plan for a model without calling it or writing anything' do
    printed = capture_stdout { run(:preview, MODEL: 'google/gemini-embedding-001') }

    expect(printed).to include('Model: google/gemini-embedding-001 (now in force: text-embedding-3-large, the apply switches it)',
                               'OpenRouter key: configured')
    expect(printed).to match(/faq\s+rows\s+1/)
    expect(Captain::Llm::EmbeddingService).not_to have_received(:new)
    expect(faq.reload.embedding_model).to eq('text-embedding-3-large')
  end

  it 'shows what apply would do and changes nothing without CONFIRM=yes' do
    expect { run(:apply, MODEL: 'google/gemini-embedding-001', BACKUP_DIR: backup_dir) }
      .to output(/Dry run, nothing changed\. Backup would go to #{Regexp.escape(backup_dir)}/).to_stdout

    expect(File.exist?(backup_dir)).to be(false)
    expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq('text-embedding-3-large')
  end

  it 'needs a MODEL and refuses a backup directory that already exists' do
    expect { run(:apply, BACKUP_DIR: backup_dir) }.to raise_error(SystemExit).and output(%r{MODEL=provider/model is required}).to_stderr

    FileUtils.mkdir_p(backup_dir)
    Rake::Task['onelink:embeddings:apply'].reenable
    expect { run(:apply, MODEL: 'google/gemini-embedding-001', BACKUP_DIR: backup_dir, CONFIRM: 'yes') }
      .to raise_error(SystemExit).and output(/already exists/).to_stderr
  end

  it 'backs up, re-embeds and switches the model with CONFIRM=yes, and restore puts everything back', :aggregate_failures do
    expect { run(:apply, MODEL: 'google/gemini-embedding-001', BACKUP_DIR: backup_dir, CONFIRM: 'yes') }
      .to output(%r{Done\. Backup: #{Regexp.escape(backup_dir)}.*faq\s+rows\s+1\s+google/gemini-embedding-001: 1}m).to_stdout
    expect(faq.reload.embedding_model).to eq('google/gemini-embedding-001')
    expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq('google/gemini-embedding-001')

    Rake::Task['onelink:embeddings:restore'].reenable
    expect { run(:restore, BACKUP_DIR: backup_dir) }.to output(/Dry run, nothing changed/).to_stdout
    expect(faq.reload.embedding_model).to eq('google/gemini-embedding-001')

    Rake::Task['onelink:embeddings:restore'].reenable
    expect { run(:restore, BACKUP_DIR: backup_dir, CONFIRM: 'yes') }.to output(/Restored\./).to_stdout
    expect(faq.reload.embedding_model).to eq('text-embedding-3-large')
    expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq('text-embedding-3-large')
  end
end
