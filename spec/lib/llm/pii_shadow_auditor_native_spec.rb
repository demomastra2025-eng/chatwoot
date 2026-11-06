require 'rails_helper'

# Opt-in native Redis proof. Uses only an isolated namespace, never FLUSHDB.
# Native pool replacement and fork exit are required for this process-isolation proof.
# rubocop:disable Style/GlobalVars, Rails/Exit
RSpec.describe Llm::PiiShadowAuditor, :pii_feedback_native do
  let(:auditor) { described_class }
  let(:tenant_id) { 991_011 }
  let(:other_id) { 991_012 }
  let(:namespace) { "pii-feedback-proof-#{SecureRandom.hex(8)}" }

  def native_pool
    proof_namespace = namespace
    proof_url = ENV.fetch('PII_FEEDBACK_REDIS_URL')
    ConnectionPool.new(size: 12) { Redis::Namespace.new(proof_namespace, redis: Redis.new(url: proof_url)) }
  end

  around do |example|
    skip 'Set PII_FEEDBACK_REDIS_URL to the isolated test Redis' if ENV['PII_FEEDBACK_REDIS_URL'].blank?
    raise 'Native proof requires Redis DB14' unless URI(ENV.fetch('PII_FEEDBACK_REDIS_URL')).path == '/14'

    original_pool = $alfred
    proof_pool = native_pool
    $alfred = proof_pool
    with_modified_env(PII_SHADOW_AUDIT_ENABLED: 'true') { example.run }
  ensure
    if proof_pool
      proof_pool.with { |conn| conn.scan_each(match: '*') { |key| conn.del(key) } }
      proof_pool.shutdown(&:close)
      $alfred = original_pool
    end
  end

  before do
    allow(Llm::PiiShadowAuditJob).to receive(:perform_later).and_return(true)
    allow(auditor).to receive(:current_minute_bucket).and_return(2_001_001)
  end

  def counters(id = tenant_id)
    Llm::PiiFeedbackMetrics.summary(account_id: id).fetch(:counters)
  end

  it 'aggregates across fresh OS processes without relying on request RAM or an async flush' do
    children = Array.new(4) do
      fork do
        $alfred = native_pool
        10.times { auditor.record_mask_pass!('да', 'да', account_id: tenant_id) }
        exit! 0
      end
    end
    expect(children.map { |pid| Process.wait2(pid).last.success? }).to all(be(true))
    expect(counters).to include('text_checks' => 40, 'skipped_no_candidates' => 40, 'admission_grants' => 0)
    expect(counters(other_id)['text_checks']).to eq(0)
  end

  it 'atomically caps 48 competing requests at 30 admissions and records every decision' do
    workers = Array.new(4) do |worker|
      fork do
        $alfred = native_pool
        12.times do |index|
          text = "Синтетикзапрос #{worker}:#{index}"
          auditor.record_mask_pass!(text, text, account_id: tenant_id)
        end
        exit! 0
      end
    end
    expect(workers.map { |pid| Process.wait2(pid).last.success? }).to all(be(true))
    expect(counters).to include('text_checks' => 48, 'eligible_checks' => 48, 'admission_grants' => 30, 'skipped_rate' => 18)
    expect(counters(other_id)['admission_grants']).to eq(0)
  end

  it 'records a concurrent duplicate only once and atomically owns completion and its counts' do
    Array.new(12) do
      Thread.new { auditor.record_mask_pass!('Повторныйсинтетик', 'Повторныйсинтетик', account_id: tenant_id) }
    end.each(&:value)
    digest = auditor.message_dedup_digest('Повторныйсинтетик', account_id: tenant_id)
    expect(auditor.acquire_inflight_audit!(digest, lease_token: 'live-owner')).to be(true)
    expect(auditor.mark_audited_digest!(digest, lease_token: 'wrong', account_id: tenant_id, counts: { audit_completed: 1 })).to be(false)
    expect(auditor.mark_audited_digest!(digest, lease_token: 'live-owner', account_id: tenant_id, counts: { audit_completed: 1 })).to be(true)
    expect(auditor.mark_audited_digest!(digest, lease_token: 'live-owner', account_id: tenant_id, counts: { audit_completed: 1 })).to be(false)
    expect(counters).to include('eligible_checks' => 12, 'admission_grants' => 1, 'skipped_duplicate' => 11, 'audit_completed' => 1)
  end

  it 'rejects expired ownership even when no replacement exists' do
    digest = auditor.message_dedup_digest('Истёкшийсинтетик', account_id: tenant_id)
    expect(auditor.acquire_inflight_audit!(digest, lease_token: 'old')).to be(true)
    $alfred.with { |conn| conn.del("#{auditor::DEDUP_REDIS_PREFIX}:inflight:#{digest}") }
    expect(auditor.mark_audited_digest!(digest, lease_token: 'old', account_id: tenant_id, counts: { audit_completed: 1 })).to be(false)
    expect(counters['audit_completed']).to eq(0)
    expect(auditor.acquire_inflight_audit!(digest, lease_token: 'new')).to be(true)
    expect(auditor.release_inflight_audit!(digest, lease_token: 'old')).to be(false)
    expect(auditor.mark_audited_digest!(digest, lease_token: 'new', account_id: tenant_id, counts: { audit_completed: 1 })).to be(true)
  end

  it 'deduplicates quarantine and verified learning across processes and keeps active names tenant scoped' do
    lexicon = Llm::PiiNameLexicon
    2.times do
      pid = fork do
        $alfred = native_pool
        lexicon.quarantine_candidate!('Синтетикпродвижение', category: :last_name, account_id: tenant_id)
        lexicon.learn_word!('Синтетикпродвижение', category: :last_name, account_id: tenant_id, verified: true)
        exit! 0
      end
      expect(Process.wait2(pid).last.success?).to be(true)
    end
    expect(lexicon.quarantine_candidate!('Синтетикпродвижение', category: :last_name, account_id: tenant_id)).to be(false)
    expect(lexicon.learn_word!('Синтетикпродвижение', category: :last_name, account_id: tenant_id, verified: true)).to be(false)
    expect(lexicon.last_name?('Синтетикпродвижение', account_id: tenant_id)).to be(true)
    expect(lexicon.last_name?('Синтетикпродвижение', account_id: other_id)).to be(false)
    $alfred.with { |conn| expect(conn.scan_each(match: '*').to_a.join).not_to include('Синтетикпродвижение') }
  end

  it 'rejects wrong-type metrics before admission or quarantine writes' do
    metrics_key = Llm::PiiFeedbackMetrics.keys(tenant_id).first
    $alfred.with { |conn| conn.set(metrics_key, 'corrupt') }
    auditor.record_mask_pass!('Повреждённыйсинтетик', 'Повреждённыйсинтетик', account_id: tenant_id)
    expect(Llm::PiiFeedbackMetrics.summary(account_id: tenant_id, global: true)[:status]).to eq(:unavailable)
    expect(Llm::PiiNameLexicon.quarantine_candidate!('Повреждённыйсинтетик', account_id: tenant_id, feedback: true)).to be(false)
    $alfred.with do |conn|
      expect(conn.scan_each(match: "#{auditor::DEDUP_REDIS_PREFIX}:*").to_a).to be_empty
      expect(conn.scan_each(match: "#{auditor::RATE_REDIS_PREFIX}:*").to_a).to be_empty
      expect(conn.scan_each(match: "#{Llm::PiiNameLexicon::QUARANTINE_REDIS_PREFIX}:*").to_a).to be_empty
    end
    expect(Llm::PiiShadowAuditJob).not_to have_received(:perform_later)
  end

  it 'rejects corrupt counters before completion or learned-set/version mutations' do # rubocop:disable RSpec/MultipleExpectations
    digest = auditor.message_dedup_digest('Повреждённыйсчётчик', account_id: tenant_id)
    expect(auditor.acquire_inflight_audit!(digest, lease_token: 'owner')).to be(true)
    $alfred.with { |conn| conn.hset(Llm::PiiFeedbackMetrics.keys(tenant_id).last, 'audit_completed', 'invalid-integer') }
    expect(auditor.mark_audited_digest!(digest, lease_token: 'owner', account_id: tenant_id, counts: { audit_completed: 1 })).to be(false)
    expect(Llm::PiiNameLexicon.learn_word!('Повреждённыйсчётчик', account_id: tenant_id, verified: true, feedback: true)).to be(false)
    $alfred.with do |conn|
      expect(conn.get("#{auditor::DEDUP_REDIS_PREFIX}:inflight:#{digest}")).to eq('owner')
      expect(conn.exists?("#{auditor::DEDUP_REDIS_PREFIX}:audited:#{digest}")).to be(false)
      expect(conn.scan_each(match: "#{Llm::PiiNameLexicon::LEARNED_REDIS_PREFIX}:*").to_a).to be_empty
      expect(conn.scan_each(match: "#{Llm::PiiNameLexicon::TENANT_VERSION_REDIS_PREFIX}:*").to_a).to be_empty
    end
    expect(counters).to be_nil
  end

  it 'validates the rate and learned stem key before creating any reservation or exact member' do
    rate_key = "#{auditor::RATE_REDIS_PREFIX}:#{tenant_id}:#{auditor.current_minute_bucket}"
    $alfred.with { |conn| conn.set(rate_key, 'not-an-integer') }
    expect(auditor.enqueue_shadow_audit!('Неверныйтиплексикон', account_id: tenant_id)).to be(false)
    lexicon = Llm::PiiNameLexicon
    stem_key = "#{lexicon::LEARNED_REDIS_PREFIX}:kv_#{lexicon.current_key_version}:acct_#{tenant_id}:first_name:stem"
    $alfred.with { |conn| conn.set(stem_key, 'wrong-type') }
    expect(lexicon.learn_word!('Неверныйтиплексикон', account_id: tenant_id, verified: true, feedback: true)).to be(false)
    $alfred.with do |conn|
      expect(conn.scan_each(match: "#{auditor::DEDUP_REDIS_PREFIX}:*").to_a).to be_empty
      expect(conn.scan_each(match: "#{lexicon::LEARNED_REDIS_PREFIX}:*:exact").to_a).to be_empty
      expect(conn.scan_each(match: "#{lexicon::TENANT_VERSION_REDIS_PREFIX}:*").to_a).to be_empty
    end
  end
end
# rubocop:enable Style/GlobalVars, Rails/Exit
