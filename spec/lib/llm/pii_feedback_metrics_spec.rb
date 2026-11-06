require 'rails_helper'

RSpec.describe Llm::PiiFeedbackMetrics do
  let(:tenant_id) { 991_001 }
  let(:other_id) { 991_002 }
  let(:auditor) { Llm::PiiShadowAuditor }
  let(:account) { instance_double(Account, id: tenant_id) }

  around do |example|
    with_modified_env(PII_SHADOW_AUDIT_ENABLED: 'true') { example.run }
  end

  before do
    [tenant_id, other_id, nil].flat_map { |id| described_class.keys(id) }.uniq.each { |key| Redis::Alfred.delete(key) }
    auditor.reset_stats!
    Llm::PiiNameLexicon.clear_cache!
    allow(Llm::PiiShadowAuditJob).to receive(:perform_later).and_return(true)
  end

  def counters(id = tenant_id)
    described_class.summary(account_id: id)[:counters]
  end

  def response(choice, confidence = 0.99)
    OpenStruct.new(answers: { 'overall' => OpenStruct.new(choice: choice, confidence: confidence) })
  end

  it 'counts text checks and unique token types including the native ten-character IIN token without candidates' do
    masked = '[PII_NAME_AAAAAAAA] [PII_NAME_AAAAAAAA] [PII_PHONE_BBBBBBBB] [IIN_TOKEN_CCCCCCCCCC]'
    auditor.record_mask_pass!('synthetic fixture', masked, account_id: tenant_id)
    expect(counters).to include('text_checks' => 1, 'checks_with_masked_pii' => 1,
                                'masked_name_tokens' => 1, 'masked_phone_tokens' => 1, 'masked_iin_tokens' => 1,
                                'skipped_no_candidates' => 1, 'eligible_checks' => 0, 'admission_grants' => 0)
    expect(Llm::PiiShadowAuditJob).not_to have_received(:perform_later)
  end

  it 'reports checks independently of successful enqueue and preserves tenant isolation' do
    2.times { auditor.record_mask_pass!('Синтетикредкий', 'Синтетикредкий', account_id: tenant_id) }
    auditor.record_mask_pass!('да', 'да', account_id: other_id)
    expect(counters).to include('text_checks' => 2, 'eligible_checks' => 2, 'admission_grants' => 1, 'skipped_duplicate' => 1)
    expect(counters(other_id)).to include('text_checks' => 1, 'eligible_checks' => 0)
    expect(described_class.summary(global: true)[:counters]['text_checks']).to eq(3)
  end

  it 'fails closed for missing or invalid tenants and requires explicit global reads' do
    auditor.record_mask_pass!('Наблюдениесинтетик', 'Наблюдениесинтетик', account_id: '991001:other')
    expect(Llm::PiiShadowAuditJob).not_to have_received(:perform_later)
    expect(described_class.summary(global: true)[:counters]['skipped_policy']).to eq(1)
    expect { described_class.summary }.to raise_error(ArgumentError)
    expect { described_class.summary(account_id: '991001:other') }.to raise_error(ArgumentError)
    expect(auditor.audit_masked_message!('Наблюдениесинтетик')[:status]).to eq(:skipped_policy)
  end

  it 'does no Redis or DB work and creates no evidence buffer when disabled' do
    with_modified_env(PII_SHADOW_AUDIT_ENABLED: 'false') do
      expect($alfred).not_to receive(:with) # rubocop:disable Style/GlobalVars
      expect(Account).not_to receive(:find_by)
      auditor.record_mask_pass!('Синтетик', 'Синтетик', account_id: tenant_id)
      expect(auditor.audit_masked_message!('Синтетик', account_id: tenant_id)[:missed]).to be_nil
    end
  end

  it 'leaves unavailable and low-confidence results unknown, never clean or confirmed misses' do
    auditor.record_mask_pass!('Неизвестнослово', 'Неизвестнослово', account_id: tenant_id)
    allow(auditor).to receive(:invoke_decider).and_return(nil, response('clean', 0.2))
    result = auditor.audit_masked_message!('Неизвестнослово', account: account)
    expect(result).to include(status: :decider_unavailable, missed: nil)
    result = auditor.audit_masked_message!('Неизвестнослово', account: account)
    expect(result).to include(status: :completed, missed: nil, suspected_miss: false)
    expect(counters).to include('audit_attempts' => 2, 'audit_unavailable' => 1, 'audit_completed' => 1,
                                'decider_unknown_predictions' => 1, 'decider_clean_predictions' => 0)
    expect(described_class.summary(account_id: tenant_id)).to include(precision: nil, recall: nil, confirmed_false_negatives: nil)
  end

  it 'counts failed attempts and successful retry completion once' do
    auditor.record_mask_pass!('Тестповторения', 'Тестповторения', account_id: tenant_id)
    attempts = 0
    allow(auditor).to receive(:invoke_decider) do
      attempts += 1
      raise Llm::OpenRouterDecisionClient::Error, 'synthetic transient' if attempts == 1

      response('clean')
    end
    expect { auditor.audit_masked_message!('Тестповторения', account: account, raise_on_transient: true) }
      .to raise_error(Llm::OpenRouterDecisionClient::Error)
    expect(auditor.audit_masked_message!('Тестповторения', account: account)[:status]).to eq(:completed)
    expect(auditor.audit_masked_message!('Тестповторения', account: account)[:status]).to eq(:deduplicated)
    expect(counters).to include('audit_attempts' => 2, 'audit_failed' => 1, 'audit_completed' => 1, 'decider_clean_predictions' => 1)
  end

  it 'does not turn a flagged prediction into active learning, a confirmed FN, or PII in summaries' do # rubocop:disable RSpec/MultipleExpectations
    prediction = response('missed_patient_name')
    prediction.answers['cand_0'] = OpenStruct.new(choice: 'patient_last_name', confidence: 0.95)
    allow(auditor).to receive(:invoke_decider).and_return(prediction)
    auditor.record_mask_pass!('Синтетиккарантин', 'Синтетиккарантин', account_id: tenant_id)
    expect(auditor.audit_masked_message!('Синтетиккарантин', account: account)).to include(missed: nil, suspected_miss: true)
    expect(counters).to include('decider_suspected_misses' => 1, 'new_quarantined_names' => 1)
    expect(Llm::PiiNameLexicon.quarantined_candidate?('Синтетиккарантин', category: :last_name, account_id: tenant_id)).to be(true)
    expect(Llm::PiiNameLexicon.quarantine_candidate!('Синтетиккарантин', category: :last_name, account_id: tenant_id)).to be(false)
    expect(Llm::PiiNameLexicon.last_name?('Синтетиккарантин', account_id: tenant_id)).to be(false)
    expect(Llm::PiiNameLexicon.last_name?('Синтетиккарантин', account_id: other_id)).to be(false)
    summary = described_class.summary(account_id: tenant_id)
    expect(summary[:completed_per_eligible_check]).to eq(1.0)
    expect(summary.to_json).not_to include('Синтетиккарантин', 'answers', 'cand_0')
    expect(summary[:rejected_predictions]).to be_nil
  end

  it 'exposes unavailable storage as unknown counters without pretending there were zero failures' do
    allow(described_class).to receive(:with_store).and_raise(IOError)
    expect(described_class.summary(account_id: tenant_id)).to include(status: :unavailable, counters: nil, recall: nil)
    expect(described_class.increment(tenant_id, audit_completed: 1)).to be(false)
  end

  it 'compensates failed enqueue without counting a completed audit' do
    allow(Llm::PiiShadowAuditJob).to receive(:perform_later).and_return(false, true)
    2.times { auditor.record_mask_pass!('Отказочередифраза', 'Отказочередифраза', account_id: tenant_id) }
    expect(counters).to include('eligible_checks' => 2, 'admission_grants' => 2, 'enqueue_failed' => 1, 'audit_completed' => 0)
  end

  it 'keeps direct diagnostic completions outside product coverage' do
    allow(auditor).to receive(:invoke_decider).and_return(response('clean'))
    auditor.audit_masked_message!('Диагностиксинтетик', account: account)
    expect(counters).to include('diagnostic_audits_completed' => 1, 'audit_completed' => 0, 'eligible_checks' => 0)
    expect(described_class.summary(account_id: tenant_id)[:completed_per_eligible_check]).to be_nil
  end
end
