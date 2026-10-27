require 'rails_helper'

# The service search is a vector search: the caller gives a LIST of mentions, they are embedded in one request, and each one gets the
# nearest services of the account with a score, or "not in the catalog" when none is close enough. The embedding model is a fake whose
# concepts are the axes of the vector space (see ServiceEmbeddingHelpers), so every similarity here is exact. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let(:min_score) { described_class::MIN_SCORE }
  # concepts: 0 thyroid ultrasound, 2 knee MRI, 4 blood test, 6 massage (not in the catalog)
  let!(:thyroid) { create(:scheduling_service, account: account, name: 'УЗИ щитовидной железы', base_price: 7000) }
  let!(:thyroid_neck) { create(:scheduling_service, account: account, name: 'УЗИ щитовидной железы и шеи', base_price: 9000) }
  let!(:knee) { create(:scheduling_service, account: account, name: 'МРТ коленного сустава', base_price: 25_000) }
  let!(:blood) { create(:scheduling_service, account: account, name: 'Общий анализ крови', base_price: 2500) }
  let!(:embedder) do
    stub_embedder(account, 'щитовидки' => unit_vector(0), 'колено' => unit_vector(2), 'кровь' => unit_vector(4), 'массаж' => unit_vector(6))
  end

  before do
    account.enable_features!('scheduling')
    index_service(thyroid, vector_at(0, 0.92))
    index_service(thyroid_neck, vector_at(0, 0.80))
    index_service(knee, vector_at(2, 0.85))
    index_service(blood, vector_at(4, 0.75))
  end

  def as_agent
    tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  it 'takes the threshold from the calibration: a service that exists is kept, a look-alike below it is not' do
    expect(min_score).to eq(0.66)
  end

  it 'declares queries as a list of strings and requires no parameter' do
    schema = tool.params_schema.deep_stringify_keys

    expect(schema.dig('properties', 'queries')).to include('type' => 'array', 'items' => { 'type' => 'string' })
    expect(schema['properties'].keys).to contain_exactly('queries', 'include_inactive', 'limit', 'offset')
    expect(Array(schema['required'])).to be_empty
  end

  describe 'a list of mentions in one call' do
    it 'embeds all mentions in one request as queries and answers each one in the order given' do
      mentions = %w[щитовидки колено кровь]
      payload = search(queries: mentions)

      expect(embedder).to have_received(:get_embeddings)
        .with(mentions, input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE).once
      expect(payload['results'].pluck('query')).to eq(mentions)
      expect(payload['results'].map { |result| result['services'].first['id'] }).to eq([thyroid.id, knee.id, blood.id])
    end

    it 'lists the best match first with its score and drops every service below the threshold' do
      result = search(queries: ['щитовидки'])['results'].first

      expect(result).to include('status' => 'found')
      expect(result['services'].pluck('id')).to eq([thyroid.id, thyroid_neck.id])
      expect(result['services'].pluck('score')).to eq([0.92, 0.8])
    end

    it 'says not_in_catalog for a mention whose best score is below the threshold, and finds the others' do
      payload = search(queries: %w[массаж колено])

      expect(payload['results'].first).to eq('query' => 'массаж', 'status' => 'not_in_catalog')
      expect(payload['results'].second).to include('query' => 'колено', 'status' => 'found')
    end

    it 'finds a service exactly at the threshold and not one hair below it' do
      index_service(blood, vector_at(4, min_score))
      expect(search(queries: ['кровь'])['results'].first['status']).to eq('found')

      index_service(blood, vector_at(4, min_score - 0.001))
      expect(search(queries: ['кровь'])['results'].first['status']).to eq('not_in_catalog')
    end

    it 'limits the services of each mention, not of the whole answer' do
      result = search(queries: ['щитовидки'], limit: 1)['results'].first

      expect(result['services'].pluck('id')).to eq([thyroid.id])
    end

    it 'accepts one string or a JSON list in a string instead of a list, drops blanks and repeats, and stops at the mention cap' do
      expect(search(queries: 'щитовидки')['results'].pluck('query')).to eq(['щитовидки'])
      expect(search(queries: '["щитовидки", "кровь"]')['results'].pluck('query')).to eq(%w[щитовидки кровь])
      expect(search(queries: ['щитовидки', ' ', 'щитовидки', ' щитовидки '])['results'].pluck('query')).to eq(['щитовидки'])

      many = Array.new(12) { |index| "щитовидки #{index}" }
      expect(search(queries: many)['results'].size).to eq(described_class::MAX_MENTIONS)
    end

    it 'finds nothing of another account and nothing that another model embedded' do
      other = create(:account)
      create(:scheduling_service, account: other, name: 'УЗИ щитовидной железы').tap { |service| index_service(service, unit_vector(0)) }
      index_service(thyroid, vector_at(0, 0.99), model: 'openai/text-embedding-3-large')

      ids = search(queries: ['щитовидки'])['results'].first['services'].pluck('id')

      expect(ids).to eq([thyroid_neck.id])
    end

    it 'does not offer an inactive service to the patient agent, but lets staff ask for it' do
      thyroid.update!(active: false)
      thyroid_neck.update!(active: false)

      expect(search(queries: ['щитовидки'])['results'].first['status']).to eq('not_in_catalog')
      staff = search(queries: ['щитовидки'], include_inactive: true)['results'].first
      expect(staff['services'].pluck('id')).to eq([thyroid.id, thyroid_neck.id])

      as_agent
      expect(search(queries: ['щитовидки'], include_inactive: true)['results'].first['status']).to eq('not_in_catalog')
    end
  end

  describe 'the answer for staff and Copilot' do
    it 'is the admin payload of each service with its price rows and the score, under the filters that were applied' do
      doctor = create(:scheduling_resource, account: account)
      price = create(:scheduling_service_price, account: account, service: thyroid, resource: doctor, active: true)

      payload = search(queries: ['щитовидки'])
      entry = payload['results'].first['services'].first

      expect(payload['filters']).to include('queries' => ['щитовидки'], 'include_inactive' => false, 'min_score' => min_score)
      expect(payload).to include('eligibility_status' => 'unverified')
      expect(entry).to include('id' => thyroid.id, 'name' => 'УЗИ щитовидной железы', 'base_price' => 7000, 'score' => 0.92)
      expect(entry['prices'].pluck('id')).to eq([price.id])
    end
  end

  describe 'the answer for the patient agent' do
    before { as_agent }

    it 'is one compact JSON line with the entry of each service and its score' do
      output = tool.execute(queries: %w[щитовидки массаж])

      expect(output).not_to include("\n")
      expect(JSON.parse(output)).to eq(
        'results' => [
          { 'query' => 'щитовидки', 'status' => 'found',
            'services' => [{ 'id' => thyroid.id, 'name' => 'УЗИ щитовидной железы', 'price' => 7000, 'duration_min' => 30, 'score' => 0.92 },
                           { 'id' => thyroid_neck.id, 'name' => 'УЗИ щитовидной железы и шеи', 'price' => 9000, 'duration_min' => 30,
                             'score' => 0.8 }] },
          { 'query' => 'массаж', 'status' => 'not_in_catalog' }
        ]
      )
    end

    it 'caps the services of a mention at the limit of the agent answer, whatever limit it asks for' do
      expect(JSON.parse(tool.execute(queries: ['щитовидки'], limit: 500)).dig('results', 0, 'services').size).to be <= 10
    end
  end

  describe 'without queries' do
    it 'lists the catalog page by page for staff, in name order' do
      page = search(limit: 2)

      expect(page).to include('total_count' => 4, 'returned_count' => 2, 'has_more' => true, 'next_offset' => 2)
      expect(page['services'].pluck('id')).to eq([knee.id, blood.id].sort_by { |id| Scheduling::Service.find(id).name })
      expect(search(limit: 2, offset: 2)).to include('returned_count' => 2, 'has_more' => false, 'next_offset' => nil)
      expect(search(offset: 100)).to include('returned_count' => 0, 'page_status' => 'offset_out_of_range')
      expect(tool.execute(offset: -1)).to include('offset must be a non-negative integer')
      expect(embedder).not_to have_received(:get_embeddings)
    end

    it 'never lists the catalog to the patient agent: it names the categories to search by instead' do
      thyroid.update!(category: 'УЗИ')
      as_agent

      expect(search).to eq(
        'status' => 'queries_required', 'total_count' => 4, 'categories' => ['УЗИ'],
        'instruction' => Captain::Tools::Agent::CatalogPayload::REFINE_QUERY_INSTRUCTION
      )
    end
  end

  describe 'when the search cannot answer' do
    it 'refuses with a clear message while no service of the account is searchable, and queues the refresh at once' do
      Scheduling::Service.where(account_id: account.id).update_all(embedding_model: nil, embedded_at: nil) # rubocop:disable Rails/SkipsModelValidations
      Redis::Alfred.delete(Scheduling::ServiceEmbeddingJob.queued_key(account.id))

      output = nil
      expect { output = tool.execute(queries: ['щитовидки']) }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob).with(account.id)
      expect(output).to include(described_class::INDEX_NOT_READY)
      expect(embedder).not_to have_received(:get_embeddings)
    end

    it 'answers from the services that are searchable while a few still wait for their vector, and queues their refresh' do
      waiting = create(:scheduling_service, account: account, name: 'Новая услуга')
      Redis::Alfred.delete(Scheduling::ServiceEmbeddingJob.queued_key(account.id))

      payload = nil
      expect { payload = search(queries: ['колено']) }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob).with(account.id)
      expect(payload['results'].first['services'].first['id']).to eq(knee.id)
      expect(waiting.reload.embedded_at).to be_nil
    end

    it 'tells an account without any service that nothing is listed (an empty catalog needs no vectors)' do
      Scheduling::Service.where(account_id: account.id).delete_all

      expect(search(queries: ['щитовидки'])['results'].first).to eq('query' => 'щитовидки', 'status' => 'not_in_catalog')
    end

    it 'reports an unavailable search, without the text of the provider error, when the embedding request fails' do
      allow(embedder).to receive(:get_embeddings).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'secret provider detail')

      output = tool.execute(queries: ['щитовидки'])

      expect(output).to include(described_class::SEARCH_UNAVAILABLE)
      expect(output).not_to include('secret provider detail')
    end

    it 'reports an unavailable search when the embedding request takes too long' do
      allow(embedder).to receive(:get_embeddings).and_raise(Timeout::Error)

      expect(tool.execute(queries: ['щитовидки'])).to include(described_class::SEARCH_UNAVAILABLE)
    end
  end

  describe '#active?' do
    it 'needs the scheduling feature of the account and a user' do
      expect(tool).to be_active
      account.disable_features!('scheduling')
      expect(described_class.new(assistant, user: user)).not_to be_active
    end
  end
end
