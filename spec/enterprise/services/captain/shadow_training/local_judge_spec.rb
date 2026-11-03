require 'rails_helper'

RSpec.describe Captain::ShadowTraining::LocalJudge do
  subject(:judge) { described_class.new }

  let(:snapshot) do
    { 'mode' => 'canonical_prompt_without_tools', 'limitations' => ['after_reply_facts'],
      'history' => [{ 'role' => 'user', 'content' => 'Қанша тұрады?' }],
      'facts' => [{ 'ref' => 'service:1', 'data' => { 'base_price' => 15_000 } }] }
  end
  let(:run) { instance_double(Captain::ShadowTraining::Run, evaluation_snapshot: snapshot, shadow_reply: '20000', human_reply: '15000') }
  let(:result) do
    { 'verdict' => 'discrepancy', 'explanation' => 'Цена отличается от каталога.',
      'discrepancies' => [{ 'description' => 'Неверная цена', 'source_refs' => ['service:1'] }], 'faq_candidates' => [] }
  end

  around do |example|
    with_modified_env(CAPTAIN_SHADOW_JUDGE_ORIGIN: 'http://127.0.0.1:18080', CAPTAIN_SHADOW_JUDGE_REGION: nil) { example.run }
  end

  before do
    allow(Captain::ShadowTraining::DataScope).to receive(:with).with(run).and_yield
    allow(Captain::ShadowTraining::Eligibility).to receive(:ensure_run!).with(run)
  end

  it 'checks native health once without patient content or waking an unavailable model' do
    request = stub_request(:get, 'http://127.0.0.1:18080/health').with(body: nil).to_return(status: 200, body: '{"status":"ok"}')
    expect(judge).to be_ready
    expect(request).to have_been_requested.once
  end

  it 'treats loading, redirects, oversized or malformed health responses as unavailable' do
    [[503, '{"status":"loading model"}'], [302, '{}'], [200, 'x' * 4097], [200, 'broken'],
     [200, '{"status":"ok","extra":true}']].each do |status, body|
      stub_request(:get, 'http://127.0.0.1:18080/health').to_return(status: status, body: body)
      expect(judge).not_to be_ready
    end
  end

  it 'sends native JSON schema to the pinned local endpoint without a paid judge' do
    request = stub_request(:post, 'http://127.0.0.1:18080/completion').with do |http|
      payload = JSON.parse(http.body)
      expect(payload['json_schema']).to include('additionalProperties' => false)
      expect(payload['prompt']).to include('Қанша тұрады?', 'A human reply is not ground truth', 'after_reply_facts')
      expect(payload['cache_prompt']).to be false
      true
    end.to_return(status: 200, body: JSON.generate(content: JSON.generate(result)))
    expect(Llm::Runtime).not_to receive(:chat)
    expect(judge.compare(run)).to eq(result)
    expect(request).to have_been_requested.once
  end

  it 'rejects public, DNS, credentials, redirects, paths and insecure private endpoints before any HTTP' do
    [
      'https://8.8.8.8', 'https://judge.example', 'http://127.0.0.1@8.8.8.8', 'http://127.0.0.1/path',
      'http://127.0.0.1?target=other', 'http://10.0.0.1', 'https://10.0.0.1', 'http://169.254.169.254', 'http://127.0.0.1/'
    ].each do |origin|
      with_modified_env(CAPTAIN_SHADOW_JUDGE_ORIGIN: origin) { expect(judge).not_to be_configured }
    end
  end

  it 'allows a private numeric HTTPS endpoint only with explicit server-owned KZ region attestation' do
    with_modified_env(CAPTAIN_SHADOW_JUDGE_ORIGIN: 'https://10.1.2.3:443', CAPTAIN_SHADOW_JUDGE_REGION: 'KZ') do
      expect(judge).to be_configured
    end
  end

  it 'never follows redirects' do
    stub_request(:post, 'http://127.0.0.1:18080/completion').to_return(status: 302, headers: { Location: 'https://8.8.8.8' })
    expect { judge.compare(run) }.to raise_error(described_class::Unavailable, 'local_judge_http_error')
  end

  it 'rejects malformed JSON, unknown keys, invented references and inconsistent verdicts' do
    values = [
      'not JSON', JSON.generate(result.merge('unexpected' => true)),
      JSON.generate(result.merge('discrepancies' => [{ 'description' => 'x', 'source_refs' => ['service:999'] }])),
      JSON.generate(result.merge('verdict' => 'equivalent'))
    ]
    values.each do |value|
      stub_request(:post, 'http://127.0.0.1:18080/completion').to_return(status: 200, body: JSON.generate(content: value))
      expect { judge.compare(run) }.to raise_error(described_class::Unavailable)
    end
  end

  it 'bounds response bytes and request bytes before further work' do
    stub_request(:post, 'http://127.0.0.1:18080/completion').to_return(status: 200, body: 'x' * 32_001)
    expect { judge.compare(run) }.to raise_error(described_class::Unavailable, 'local_judge_response_too_large')
    snapshot['history'][0]['content'] = 'x' * 96_000
    expect { judge.compare(run) }.to raise_error(described_class::Unavailable, 'local_judge_input_too_large')
  end

  it 'preflights the exact double-escaped boundary including worst-case bounded shadow output' do
    allow(run).to receive(:snapshot).and_return('agent_contexts' => { '1' => {} })
    data = judge.send(:input, run, snapshot: snapshot, shadow_reply: "\0" * Captain::ShadowTraining::Generator::MAX_REPLY)
    baseline_bytes = judge.send(:payload_for, data).bytesize
    snapshot['history'][0]['content'] += 'x' * (described_class::MAX_REQUEST_BYTES - baseline_bytes)
    expect(judge.representable?(run)).to be true
    snapshot['history'][0]['content'] += 'x'
    expect(judge.representable?(run)).to be false
  end

  it 'reports timeouts safely without logging raw content or falling back to OpenRouter' do
    stub_request(:post, 'http://127.0.0.1:18080/completion').to_timeout
    expect(Llm::Runtime).not_to receive(:chat)
    expect(Rails.logger).not_to receive(:error)
    expect { judge.compare(run) }.to raise_error(described_class::Unavailable, 'local_judge_unavailable_or_invalid')
  end

  it 'rejects a personal privacy token in a reusable FAQ candidate' do
    value = result.merge('faq_candidates' => [{ 'question' => 'Цена для [PII_NAME_DEADBEEF]?', 'answer' => '15000',
                                                'source_refs' => ['service:1'] }])
    stub_request(:post, 'http://127.0.0.1:18080/completion').to_return(status: 200, body: JSON.generate(content: JSON.generate(value)))
    expect { judge.compare(run) }.to raise_error(described_class::Unavailable)
  end
end
