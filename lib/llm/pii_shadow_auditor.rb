# frozen_string_literal: true

require 'securerandom'
require_relative 'pii_name_lexicon'
require_relative 'open_router_workspace_policy'
require_relative 'open_router_headers'
require_relative 'budget_evaluator'

# Asynchronous shadow auditor & real-time telemetry for PII pseudonymization.
#
# Key safety guarantees:
# 1. Zero hot-path I/O when OFF: `record_mask_pass!` updates in-memory counters only (0 sync Redis/DB calls
#    when `PII_SHADOW_AUDIT_ENABLED` is false). When ON and candidate words require background audit, admission
#    uses a single atomic Redis Lua script (`ENQUEUE_ADMISSION_SCRIPT`).
# 2. Fail-closed kill switch & admission: `record_mask_pass!`, `Llm::PiiShadowAuditJob`, and `audit_masked_message!`
#    verify `shadow_audit_enabled?` before any enqueue or network dispatch, and fail closed (`false`) if Redis
#    admission errors.
# 3. Cross-worker atomic deduplication, rate cap, and lease-based in-flight retry boundaries: role/protocol
#    strings (`user`, `assistant`, `system`, `tool`) are excluded; enqueue deduplication, per-account minute
#    rate caps (`MAX_AUDITS_PER_MINUTE_PER_ACCOUNT`), and token-leased `in_flight` / `audited` transitions are
#    enforced atomically across workers via Redis Lua scripts (`EVAL`). Transient transport failures release
#    the caller's `in_flight` lease in `ensure` without marking `audited`, allowing `retry_on` to re-dispatch.
# 4. Workspace privacy, ZDR, provider routing, and budget enforcement: compiles `provider` preferences
#    (`only`, `ignore`, `order`, `data_collection: deny`, `zdr: true`, `allow_fallbacks`) via
#    `Llm::OpenRouterRoutingProfile` + `Llm::OpenRouterWorkspacePolicy`, resolves account keys via
#    `Llm::Config.api_key(:openrouter, account:)`, and checks `Llm::BudgetEvaluator`.
# 5. Hostile-LLM quarantine & tenant isolation: decider candidate answers never directly mutate the active
#    `Llm::PiiNameLexicon`. Contradictory answers (`overall == clean`) are rejected; flagged candidates go
#    only into a tenant-scoped quarantine until deterministically verified (e.g. at the booking tool boundary).
# rubocop:disable Metrics/ModuleLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Style/GlobalVars
module Llm::PiiShadowAuditor
  STATS_REDIS_KEY = 'llm:pii_shadow_audit:stats:v2'
  DEDUP_REDIS_PREFIX = 'llm:pii_shadow_audit:dedup:v2'
  RATE_REDIS_PREFIX = 'llm:pii_shadow_audit:rate:v2'
  DEDUP_TTL_SECONDS = 3_600
  INFLIGHT_TTL_SECONDS = 60
  RATE_TTL_SECONDS = 120
  DEFAULT_DECIDER_MODEL = 'perplexity/pplx-decider-v1.2'
  FEATURE_KEY = 'custom_guardrail'
  CONFIDENCE_THRESHOLD = 0.80
  MAX_CANDIDATE_QUESTIONS = 12
  MAX_DEDUP_ENTRIES = 4_096
  MAX_AUDITS_PER_MINUTE_PER_ACCOUNT = 30

  # KEYS: [1] enqueued_key, [2] audited_key, [3] rate_key
  # ARGV: [1] max_per_min, [2] dedup_ttl, [3] rate_ttl
  ENQUEUE_ADMISSION_SCRIPT = <<~LUA
    if redis.call('EXISTS', KEYS[1]) == 1 or redis.call('EXISTS', KEYS[2]) == 1 then
      return 0
    end
    local current = tonumber(redis.call('GET', KEYS[3]) or '0')
    if current >= tonumber(ARGV[1]) then
      return 0
    end
    redis.call('SET', KEYS[1], '1', 'EX', tonumber(ARGV[2]))
    local next_val = redis.call('INCR', KEYS[3])
    if next_val == 1 then
      redis.call('EXPIRE', KEYS[3], tonumber(ARGV[3]))
    end
    return 1
  LUA

  # KEYS: [1] enqueued_key, [2] rate_key
  RELEASE_ENQUEUE_SCRIPT = <<~LUA
    local removed = redis.call('DEL', KEYS[1])
    if removed == 1 then
      local current = tonumber(redis.call('GET', KEYS[2]) or '0')
      if current > 0 then
        redis.call('DECR', KEYS[2])
      end
    end
    return removed
  LUA

  # KEYS: [1] inflight_key, [2] audited_key
  # ARGV: [1] lease_token, [2] inflight_ttl
  ACQUIRE_INFLIGHT_SCRIPT = <<~LUA
    if redis.call('EXISTS', KEYS[2]) == 1 or redis.call('EXISTS', KEYS[1]) == 1 then
      return 0
    end
    redis.call('SET', KEYS[1], ARGV[1], 'EX', tonumber(ARGV[2]))
    return 1
  LUA

  # KEYS: [1] inflight_key, [2] audited_key
  # ARGV: [1] lease_token, [2] dedup_ttl
  COMPLETE_AUDIT_SCRIPT = <<~LUA
    local owner = redis.call('GET', KEYS[1])
    if ARGV[1] ~= '' and owner and owner ~= ARGV[1] then
      return 0
    end
    redis.call('SET', KEYS[2], '1', 'EX', tonumber(ARGV[2]))
    if ARGV[1] == '' or owner == ARGV[1] then
      redis.call('DEL', KEYS[1])
    end
    return 1
  LUA

  # KEYS: [1] inflight_key
  # ARGV: [1] lease_token
  RELEASE_INFLIGHT_SCRIPT = <<~LUA
    if ARGV[1] == '' or redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[1])
    end
    return 0
  LUA

  CANDIDATE_CHOICE_CATEGORIES = {
    'patient_first_name' => :first_name,
    'patient_last_name' => :last_name,
    'patient_patronymic' => :patronymic
  }.freeze

  CANDIDATE_CRITERIA = {
    'patient_first_name' => 'The word is a personal given/first name of a patient or client (not a doctor, medical term, city, or common word).',
    'patient_last_name' => 'The word is a family/surname of a patient or client (not a doctor, clinic, or common word).',
    'patient_patronymic' => 'The word is a patronymic/middle name of a patient or client.',
    'not_patient_pii' => 'The word is a common word, greeting, medical term, service name, clinic name, or a doctor name.'
  }.freeze

  MESSAGE_CRITERIA = {
    'clean' => 'No unmasked personal data of the patient remains in plain text ' \
               '(patient PII is already masked with [PII_...] or [IIN_TOKEN_...] tokens, or only doctor/clinic names are present).',
    'missed_patient_name' => 'An unmasked personal name, surname, or patronymic of the PATIENT remains in plain text.',
    'missed_patient_contact_or_id' => 'An unmasked phone number, IIN, or document number of the PATIENT remains in plain text.'
  }.freeze

  PROTOCOL_WORDS = %w[
    user assistant system tool function developer model role content text type
    message messages input output metadata tool_call tool_calls arguments
  ].to_set.freeze

  TRIVIAL_MESSAGES = %w[
    да нет ок хорошо спасибо рахмет салем сәлем здравствуйте добрый день вечер утро привет
    yes no ok okay thanks hello hi
  ].to_set.freeze

  BudgetRequestStub = Struct.new(:feature_key, :account, :model, keyword_init: true)

  @local_stats = Hash.new(0)
  @pending_redis_increments = Hash.new(0)
  @enqueued_digests = Set.new
  @inflight_digests = Set.new
  @inflight_leases = {}
  @audited_digests = Set.new
  @rate_windows = {}
  @tracked_redis_keys = Set.new
  @stats_mutex = Mutex.new

  module_function

  # Hot-path hook: 0 synchronous Redis or DB calls when shadow audit is OFF;
  # 1 atomic Redis admission evaluation when shadow audit is ON and enqueueing.
  def record_mask_pass!(original_text, masked_text, account_id: nil, enqueue_async: true)
    return if original_text.blank?

    stripped = original_text.to_s.strip
    return if PROTOCOL_WORDS.include?(stripped.downcase)

    name_tokens = masked_text.to_s.scan(/\[PII_NAME_[0-9A-F]{8}\]/).uniq.size
    phone_tokens = masked_text.to_s.scan(/\[PII_PHONE_[0-9A-F]{8}\]/).uniq.size
    iin_tokens = masked_text.to_s.scan(/\[IIN_TOKEN_[0-9A-F]{8}\]/).uniq.size
    total_caught = name_tokens + phone_tokens + iin_tokens

    increment_stat_in_memory!(:messages_scanned, 1)
    if total_caught.positive?
      increment_stat_in_memory!(:messages_with_caught_pii, 1)
      increment_stat_in_memory!(:caught_names_total, name_tokens) if name_tokens.positive?
      increment_stat_in_memory!(:caught_phones_total, phone_tokens) if phone_tokens.positive?
      increment_stat_in_memory!(:caught_iins_total, iin_tokens) if iin_tokens.positive?
    end

    return unless enqueue_async && shadow_audit_enabled?
    return unless requires_shadow_audit?(masked_text)

    enqueue_shadow_audit!(masked_text, account_id: account_id)
  rescue StandardError
    nil
  end

  # Deterministic Layer-1 verification at the booking tool boundary (`Verified: true`).
  def record_tool_boundary_check!(raw_first_name: nil, raw_last_name: nil, raw_middle_name: nil, account_id: nil, session_contained_token: false)
    eff_account_id = resolve_effective_account_id(account_id)
    pairs = [
      [raw_first_name, :first_name],
      [raw_last_name, :last_name],
      [raw_middle_name, :patronymic]
    ]

    learned_any = false
    pairs.each do |raw_val, cat|
      word = raw_val.to_s.strip
      next if word.blank? || word.include?('[PII_')

      next if Llm::PiiNameLexicon.known_person_name_word?(word, account_id: eff_account_id)

      increment_stat_in_memory!(:missed_names_caught_at_tool_boundary, 1) unless session_contained_token
      if eff_account_id.present? && Llm::PiiNameLexicon.learn_word!(word, category: cat, account_id: eff_account_id, verified: true)
        increment_stat_in_memory!(:auto_learned_names_total, 1)
        learned_any = true
      end
    end
    learned_any
  rescue StandardError
    false
  end

  def requires_shadow_audit?(masked_text)
    return false if masked_text.blank?

    stripped = masked_text.to_s.strip
    return false if stripped.length < 3
    return false if PROTOCOL_WORDS.include?(stripped.downcase)

    extract_candidate_words(stripped).any?
  end

  def extract_candidate_words(text)
    cleaned = text.to_s.gsub(/\[(?:PII_[A-Z]+_[0-9A-F]+|IIN_TOKEN_[0-9A-F]+)\]/, ' ')
    stopwords = defined?(Llm::PiiSessionPseudonymizer::STATIC_STOPWORDS) ? Llm::PiiSessionPseudonymizer::STATIC_STOPWORDS : Set.new
    tokens = cleaned.scan(/[[:alpha:]-]{3,}/)
    tokens.uniq.reject do |w|
      norm = Llm::PiiNameLexicon.normalize_word(w)
      stem = Llm::PiiNameLexicon.stem_word(norm)
      PROTOCOL_WORDS.include?(norm) || TRIVIAL_MESSAGES.include?(norm) || stopwords.include?(norm) || stopwords.include?(stem)
    end.first(MAX_CANDIDATE_QUESTIONS)
  end

  def audit_masked_message!(masked_text, account_id: nil, account: nil, decision_client: nil, privacy_profile: nil,
                            runtime_preferences: nil, allow_when_disabled: false, raise_on_transient: false)
    return { status: :disabled, missed: false, learned: [], quarantined: [] } unless shadow_audit_enabled? || allow_when_disabled

    eff_account_id = resolve_effective_account_id(account_id || account&.try(:id))
    candidates = extract_candidate_words(masked_text)
    return { status: :skipped_no_candidates, missed: false, learned: [], quarantined: [] } if candidates.empty?

    msg_digest = message_dedup_digest(masked_text, account_id: eff_account_id)
    lease_token = "#{Process.pid}:#{Thread.current.object_id}:#{SecureRandom.hex(8)}"
    slot_acquired = acquire_inflight_audit!(msg_digest, lease_token: lease_token)
    return { status: :deduplicated, missed: false, learned: [], quarantined: [] } unless slot_acquired

    audit_completed = false
    increment_stat_in_memory!(:shadow_audits_run, 1)
    flush_stats_to_redis!

    questions = build_decision_questions(masked_text, candidates)
    response = invoke_decider(
      masked_text, questions,
      account_id: eff_account_id, account: account, decision_client: decision_client,
      privacy_profile: privacy_profile, runtime_preferences: runtime_preferences
    )
    return { status: :decider_unavailable, missed: false, learned: [], quarantined: [] } unless response

    res = process_decider_response!(response, candidates, account_id: eff_account_id)
    mark_audited_digest!(msg_digest, lease_token: lease_token)
    audit_completed = true
    flush_stats_to_redis!
    res
  rescue StandardError => e
    raise if raise_on_transient && transient_decision_error?(e)

    { status: :error, error_class: e.class.name, missed: false, learned: [], quarantined: [] }
  ensure
    release_inflight_audit!(msg_digest, lease_token: lease_token) if slot_acquired && !audit_completed
  end

  def compile_decision_request_options(account_id: nil, account: nil, model: DEFAULT_DECIDER_MODEL,
                                       privacy_profile: nil, runtime_preferences: nil)
    resolved_acct = resolve_account_object(account, account_id)
    eff_account_id = resolved_acct&.try(:id) || account_id

    budget_req = BudgetRequestStub.new(feature_key: FEATURE_KEY, account: resolved_acct, model: model)
    if defined?(Llm::BudgetEvaluator)
      decision = Llm::BudgetEvaluator.evaluate!(request: budget_req, model: model)
      raise ArgumentError, "Budget blocked for #{FEATURE_KEY}" if decision.respond_to?(:blocked?) && decision.blocked?
    end

    ws_policy = Llm::OpenRouterWorkspacePolicy.resolve(
      account: resolved_acct,
      preferences: runtime_preferences,
      privacy_profile: privacy_profile
    )
    provider_prefs = build_routed_provider_preferences(
      ws_policy: ws_policy,
      account: resolved_acct,
      model: model,
      privacy_profile: privacy_profile,
      runtime_preferences: runtime_preferences
    )
    if provider_prefs[:zdr] == true && defined?(Llm::OpenRouterDecisionClient) &&
       !Llm::OpenRouterDecisionClient.zdr_supported_model?(model)
      raise ArgumentError, "Decision model #{model} does not satisfy ZDR policy"
    end

    built_headers = Llm::OpenRouterHeaders.build(
      include_cache: false,
      provider_params: provider_prefs,
      native_endpoint: '/alpha/decisions',
      privacy_profile: ws_policy.privacy_profile,
      trace_capture_allowed: ws_policy.trace_capture_allowed?
    )

    {
      model: model,
      feature: FEATURE_KEY,
      account_id: eff_account_id,
      privacy_profile: ws_policy.privacy_profile,
      provider: provider_prefs,
      headers: built_headers.headers,
      timeout: 5
    }
  end

  def stats
    redis_stats = fetch_redis_stats
    @stats_mutex.synchronize do
      merged = @local_stats.dup
      redis_stats.each { |k, v| merged[k.to_sym] = [merged[k.to_sym].to_i, v.to_i].max }
      merged
    end
  end

  def flush_stats_to_redis!
    return unless defined?(Redis::Alfred)

    deltas = @stats_mutex.synchronize do
      next {} if @pending_redis_increments.empty?

      snap = @pending_redis_increments.dup
      @pending_redis_increments.clear
      snap
    end
    deltas.each { |k, v| redis_hincrby(STATS_REDIS_KEY, k.to_s, v.to_i) if v.to_i.positive? }
  rescue StandardError
    nil
  end

  def reset_stats!
    tracked = @stats_mutex.synchronize do
      @local_stats.clear
      @pending_redis_increments.clear
      @enqueued_digests.clear
      @inflight_digests.clear
      (@inflight_leases ||= {}).clear
      @audited_digests.clear
      @rate_windows.clear
      keys = @tracked_redis_keys.to_a
      @tracked_redis_keys.clear
      keys
    end
    redis_del(STATS_REDIS_KEY)
    (tracked + scan_auditor_redis_keys).uniq.each { |k| redis_del(k) }
  rescue StandardError
    nil
  end

  def shadow_audit_enabled?
    ENV['PII_SHADOW_AUDIT_ENABLED'] == 'true'
  end

  def enqueue_shadow_audit!(masked_text, account_id: nil)
    return false unless shadow_audit_enabled?
    return false unless defined?(Llm::PiiShadowAuditJob)

    eff_account_id = resolve_effective_account_id(account_id)
    msg_digest = message_dedup_digest(masked_text, account_id: eff_account_id)
    admitted_minute = current_minute_bucket
    return false unless allow_enqueue_digest_and_rate?(msg_digest, eff_account_id, minute_bucket: admitted_minute)

    begin
      job_res = Llm::PiiShadowAuditJob.perform_later(masked_text.to_s, account_id: eff_account_id)
      unless enqueue_succeeded?(job_res)
        release_enqueue_admission!(msg_digest, eff_account_id, minute_bucket: admitted_minute)
        return false
      end
    rescue StandardError
      release_enqueue_admission!(msg_digest, eff_account_id, minute_bucket: admitted_minute)
      return false
    end
    true
  rescue StandardError
    false
  end

  def enqueue_succeeded?(job_result)
    return false if job_result == false || job_result.nil?
    return job_result.successfully_enqueued? if job_result.respond_to?(:successfully_enqueued?)

    true
  end

  def current_minute_bucket
    (Process.clock_gettime(Process::CLOCK_REALTIME) / 60.0).floor
  end

  def message_dedup_digest(masked_text, account_id: nil)
    Llm::PiiNameLexicon.send(:hmac_digest, "shadow_dedup:#{account_id.to_i}:#{masked_text.to_s.strip}").unpack1('H*')
  end

  def allow_enqueue_digest_and_rate?(msg_digest, account_id, minute_bucket: nil)
    now_min = minute_bucket || current_minute_bucket
    rate_key = "#{account_id.to_i}:#{now_min}"
    enq_rkey = "#{DEDUP_REDIS_PREFIX}:enqueued:#{msg_digest}"
    aud_rkey = "#{DEDUP_REDIS_PREFIX}:audited:#{msg_digest}"
    rate_rkey = "#{RATE_REDIS_PREFIX}:#{rate_key}"

    @stats_mutex.synchronize do
      return false if @enqueued_digests.include?(msg_digest) || @audited_digests.include?(msg_digest)
      return false if @rate_windows[rate_key].to_i >= MAX_AUDITS_PER_MINUTE_PER_ACCOUNT

      admitted = redis_atomic_enqueue_admission(enq_rkey, aud_rkey, rate_rkey)
      return false unless admitted

      @enqueued_digests.clear if @enqueued_digests.size >= MAX_DEDUP_ENTRIES
      @enqueued_digests << msg_digest
      @rate_windows.delete_if { |k, _| !k.end_with?(":#{now_min}") }
      @rate_windows[rate_key] = @rate_windows[rate_key].to_i + 1
      @tracked_redis_keys << enq_rkey
      @tracked_redis_keys << rate_rkey
      true
    end
  rescue StandardError
    false
  end

  def release_enqueue_admission!(msg_digest, account_id, minute_bucket: nil)
    now_min = minute_bucket || current_minute_bucket
    rate_key = "#{account_id.to_i}:#{now_min}"
    enq_rkey = "#{DEDUP_REDIS_PREFIX}:enqueued:#{msg_digest}"
    rate_rkey = "#{RATE_REDIS_PREFIX}:#{rate_key}"

    @stats_mutex.synchronize do
      @enqueued_digests.delete(msg_digest)
      @rate_windows[rate_key] = [@rate_windows[rate_key].to_i - 1, 0].max
      redis_atomic_release_enqueue(enq_rkey, rate_rkey)
    end
  rescue StandardError
    nil
  end

  def acquire_inflight_audit!(msg_digest, lease_token: nil)
    token = lease_token.presence || "#{Process.pid}:#{Thread.current.object_id}:#{SecureRandom.hex(8)}"
    aud_rkey = "#{DEDUP_REDIS_PREFIX}:audited:#{msg_digest}"
    inf_rkey = "#{DEDUP_REDIS_PREFIX}:inflight:#{msg_digest}"

    @stats_mutex.synchronize do
      return false if @audited_digests.include?(msg_digest) || @inflight_digests.include?(msg_digest)

      acquired = redis_atomic_acquire_inflight(inf_rkey, aud_rkey, token)
      return false unless acquired

      @inflight_digests << msg_digest
      (@inflight_leases ||= {})[msg_digest] = token
      @tracked_redis_keys << inf_rkey
      true
    end
  rescue StandardError
    false
  end

  def release_inflight_audit!(msg_digest, lease_token: nil)
    inf_rkey = "#{DEDUP_REDIS_PREFIX}:inflight:#{msg_digest}"
    @stats_mutex.synchronize do
      leases = (@inflight_leases ||= {})
      expected = lease_token.presence || leases[msg_digest].to_s
      released = redis_atomic_release_inflight(inf_rkey, expected)
      if released || expected.blank? || leases[msg_digest] == expected
        @inflight_digests.delete(msg_digest)
        leases.delete(msg_digest)
      end
      released
    end
  rescue StandardError
    false
  end

  def mark_audited_digest!(msg_digest, lease_token: nil)
    aud_rkey = "#{DEDUP_REDIS_PREFIX}:audited:#{msg_digest}"
    inf_rkey = "#{DEDUP_REDIS_PREFIX}:inflight:#{msg_digest}"
    @stats_mutex.synchronize do
      leases = (@inflight_leases ||= {})
      expected = lease_token.presence || leases[msg_digest].to_s
      completed = redis_atomic_complete_audit(inf_rkey, aud_rkey, expected)
      return false unless completed

      @inflight_digests.delete(msg_digest)
      leases.delete(msg_digest)
      @audited_digests.clear if @audited_digests.size >= MAX_DEDUP_ENTRIES
      @audited_digests << msg_digest
      @tracked_redis_keys << aud_rkey
      true
    end
  rescue StandardError
    false
  end

  def build_routed_provider_preferences(ws_policy:, account:, model:, privacy_profile:, runtime_preferences:)
    base = ws_policy.provider_preferences.dup
    return base unless defined?(Llm::OpenRouterRoutingProfile) && Llm::OpenRouterRoutingProfile.respond_to?(:for)

    prefs = (runtime_preferences || {}).to_h.deep_stringify_keys
    prefs['privacy_profile'] = privacy_profile.to_s if privacy_profile.present?
    routing_profile = Llm::OpenRouterRoutingProfile.for(
      feature: FEATURE_KEY,
      model: model,
      account: account,
      runtime_preferences: prefs
    )
    routing_profile.provider_preferences.deep_dup.merge(base)
  rescue StandardError
    base
  end

  def build_decision_questions(_masked_text, candidates)
    questions = {
      'overall' => {
        criteria: MESSAGE_CRITERIA,
        instructions: 'Examine the already-masked patient chat message in state.message. Tokens like [PII_NAME_...] or [IIN_TOKEN_...] ' \
                      'are already masked. Determine if any unmasked personal data of the PATIENT (not doctors or clinics) remains in plain text.'
      }
    }
    candidates.each_with_index do |word, idx|
      questions["cand_#{idx}"] = {
        criteria: CANDIDATE_CRITERIA,
        instructions: "In the context of state.message, classify the word \"#{word}\". Ignore doctor names and clinic names; " \
                      "only classify as patient_first_name, patient_last_name, or patient_patronymic if \"#{word}\" is the patient/client."
      }
    end
    questions
  end

  def invoke_decider(masked_text, questions, account_id: nil, account: nil, decision_client: nil,
                     privacy_profile: nil, runtime_preferences: nil)
    client = decision_client || (defined?(Llm::OpenRouterDecisionClient) ? Llm::OpenRouterDecisionClient : nil)
    return nil unless client

    compiled_opts = compile_decision_request_options(
      account_id: account_id, account: account, model: DEFAULT_DECIDER_MODEL,
      privacy_profile: privacy_profile, runtime_preferences: runtime_preferences
    )
    api_key = resolve_api_key(account, account_id)
    return nil if api_key.blank? && decision_client.nil?

    if client.respond_to?(:choose)
      client.choose(
        state: { message: masked_text.to_s },
        questions: questions,
        api_key: api_key.presence || 'test-key',
        **compiled_opts
      )
    elsif client.respond_to?(:decide)
      client.decide(
        state: { message: masked_text.to_s },
        questions: questions,
        **compiled_opts
      )
    end
  end

  def process_decider_response!(response, candidates, account_id: nil)
    answers = response.respond_to?(:answers) ? response.answers.to_h : {}
    overall = answers['overall']
    overall_flagged = overall && overall.choice.to_s != 'clean' && overall.confidence.to_f >= CONFIDENCE_THRESHOLD

    quarantined = []
    if overall_flagged
      candidates.each_with_index do |word, idx|
        ans = answers["cand_#{idx}"]
        next unless ans && ans.confidence.to_f >= CONFIDENCE_THRESHOLD

        category = CANDIDATE_CHOICE_CATEGORIES[ans.choice.to_s]
        next unless category

        next unless Llm::PiiNameLexicon.quarantine_candidate!(
          word, category: category, account_id: account_id, confidence: ans.confidence.to_f, source: 'decider'
        )

        quarantined << { word: word, category: category, confidence: ans.confidence.to_f }
      end
    end

    if overall_flagged
      increment_stat_in_memory!(:missed_pii_caught_by_decider, 1)
      increment_stat_in_memory!(:quarantined_names_total, quarantined.size) if quarantined.any?
    end

    {
      status: :completed,
      missed: overall_flagged == true,
      overall_choice: overall&.choice,
      learned: [],
      quarantined: quarantined
    }
  end

  def resolve_effective_account_id(account_id)
    return account_id if account_id.present?
    return Llm::PiiSessionPseudonymizer.current_scope[:account_id] if defined?(Llm::PiiSessionPseudonymizer) && Llm::PiiSessionPseudonymizer.active?

    nil
  end

  def resolve_account_object(account, account_id)
    return account if account.present?
    return nil if account_id.blank?
    return Account.find_by(id: account_id) if defined?(Account) && Account.respond_to?(:find_by)

    nil
  rescue StandardError
    nil
  end

  def resolve_api_key(account, account_id)
    resolved_acct = resolve_account_object(account, account_id)
    if defined?(Llm::Config)
      if Llm::Config.respond_to?(:api_key)
        cfg_key = Llm::Config.api_key(:openrouter, account: resolved_acct).to_s
        return cfg_key if cfg_key.present?
      elsif Llm::Config.respond_to?(:api_key_for)
        cfg_key = Llm::Config.api_key_for(:openrouter, resolved_acct).to_s
        return cfg_key if cfg_key.present?
      end
    end
    return ENV['OPENROUTER_API_KEY'].to_s if ENV['OPENROUTER_API_KEY'].present?
    return nil unless defined?(InstallationConfig)

    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_ROUTER_API_KEY')&.value.to_s
  rescue StandardError
    nil
  end

  def transient_decision_error?(error)
    defined?(Llm::OpenRouterDecisionClient::Error) && error.is_a?(Llm::OpenRouterDecisionClient::Error)
  end

  def increment_stat_in_memory!(key, delta = 1)
    @stats_mutex.synchronize do
      @local_stats[key.to_sym] += delta.to_i
      @pending_redis_increments[key.to_sym] += delta.to_i
    end
  end

  def redis_configured?
    (defined?($alfred) && $alfred.respond_to?(:with)) || defined?(Redis::Alfred)
  end

  def native_eval_supported?(conn)
    return false if defined?(::MockRedis) && (conn.instance_of?(::MockRedis) || (conn.respond_to?(:redis) && conn.redis.instance_of?(::MockRedis)))

    conn.respond_to?(:call_with_namespace) || conn.respond_to?(:eval)
  end

  def eval_redis_lua(conn, script, keys:, argv:)
    if conn.respond_to?(:call_with_namespace)
      conn.call_with_namespace(:eval, script, keys: keys, argv: argv)
    else
      conn.eval(script, keys: keys, argv: argv)
    end
  end

  def redis_atomic_enqueue_admission(enq_rkey, aud_rkey, rate_rkey)
    return true unless redis_configured?
    return false unless defined?($alfred) && $alfred.respond_to?(:with)

    $alfred.with do |conn|
      if native_eval_supported?(conn)
        res = eval_redis_lua(
          conn, ENQUEUE_ADMISSION_SCRIPT,
          keys: [enq_rkey, aud_rkey, rate_rkey],
          argv: [MAX_AUDITS_PER_MINUTE_PER_ACCOUNT.to_s, DEDUP_TTL_SECONDS.to_s, RATE_TTL_SECONDS.to_s]
        )
        return res.to_i == 1
      elsif conn.respond_to?(:atomic)
        return conn.atomic do |store|
          next false if store[enq_rkey].present? || store[aud_rkey].present?

          cur = store[rate_rkey].to_i
          next false if cur >= MAX_AUDITS_PER_MINUTE_PER_ACCOUNT

          store[enq_rkey] = '1'
          store[rate_rkey] = (cur + 1).to_s
          true
        end
      else
        return false if conn.get(enq_rkey).present? || conn.get(aud_rkey).present?

        cur = conn.get(rate_rkey).to_i
        return false if cur >= MAX_AUDITS_PER_MINUTE_PER_ACCOUNT

        conn.set(enq_rkey, '1', ex: DEDUP_TTL_SECONDS)
        conn.set(rate_rkey, (cur + 1).to_s, ex: RATE_TTL_SECONDS)
        true
      end
    end
  rescue StandardError
    false
  end

  def redis_atomic_release_enqueue(enq_rkey, rate_rkey)
    return true unless defined?($alfred) && $alfred.respond_to?(:with)

    $alfred.with do |conn|
      if native_eval_supported?(conn)
        eval_redis_lua(conn, RELEASE_ENQUEUE_SCRIPT, keys: [enq_rkey, rate_rkey], argv: [])
      elsif conn.respond_to?(:atomic)
        conn.atomic do |store|
          if store.delete(enq_rkey)
            cur = store[rate_rkey].to_i
            store[rate_rkey] = [cur - 1, 0].max.to_s if cur.positive?
          end
        end
      else
        conn.del(enq_rkey)
      end
    end
    true
  rescue StandardError
    false
  end

  def redis_atomic_acquire_inflight(inf_rkey, aud_rkey, token)
    return true unless redis_configured?
    return false unless defined?($alfred) && $alfred.respond_to?(:with)

    $alfred.with do |conn|
      if native_eval_supported?(conn)
        res = eval_redis_lua(
          conn, ACQUIRE_INFLIGHT_SCRIPT,
          keys: [inf_rkey, aud_rkey],
          argv: [token.to_s, INFLIGHT_TTL_SECONDS.to_s]
        )
        return res.to_i == 1
      elsif conn.respond_to?(:atomic)
        return conn.atomic do |store|
          next false if store[aud_rkey].present? || store[inf_rkey].present?

          store[inf_rkey] = token.to_s
          true
        end
      else
        return false if conn.get(aud_rkey).present? || conn.get(inf_rkey).present?

        conn.set(inf_rkey, token.to_s, ex: INFLIGHT_TTL_SECONDS)
        true
      end
    end
  rescue StandardError
    false
  end

  def redis_atomic_release_inflight(inf_rkey, token)
    return true unless defined?($alfred) && $alfred.respond_to?(:with)

    $alfred.with do |conn|
      if native_eval_supported?(conn)
        res = eval_redis_lua(conn, RELEASE_INFLIGHT_SCRIPT, keys: [inf_rkey], argv: [token.to_s])
        return res.to_i == 1
      elsif conn.respond_to?(:atomic)
        return conn.atomic do |store|
          next false unless token.blank? || store[inf_rkey] == token.to_s

          !store.delete(inf_rkey).nil?
        end
      else
        cur = conn.get(inf_rkey)
        return false unless token.blank? || cur == token.to_s

        conn.del(inf_rkey)
        true
      end
    end
  rescue StandardError
    false
  end

  def redis_atomic_complete_audit(inf_rkey, aud_rkey, token)
    return true unless redis_configured?
    return false unless defined?($alfred) && $alfred.respond_to?(:with)

    $alfred.with do |conn|
      if native_eval_supported?(conn)
        res = eval_redis_lua(
          conn, COMPLETE_AUDIT_SCRIPT,
          keys: [inf_rkey, aud_rkey],
          argv: [token.to_s, DEDUP_TTL_SECONDS.to_s]
        )
        return res.to_i == 1
      elsif conn.respond_to?(:atomic)
        return conn.atomic do |store|
          owner = store[inf_rkey]
          next false if token.present? && owner.present? && owner != token.to_s

          store[aud_rkey] = '1'
          store.delete(inf_rkey) if token.blank? || owner == token.to_s
          true
        end
      else
        owner = conn.get(inf_rkey)
        return false if token.present? && owner.present? && owner != token.to_s

        conn.set(aud_rkey, '1', ex: DEDUP_TTL_SECONDS)
        conn.del(inf_rkey) if token.blank? || owner == token.to_s
        true
      end
    end
  rescue StandardError
    false
  end

  def redis_del(key)
    return nil unless defined?(Redis::Alfred) && Redis::Alfred.respond_to?(:delete)

    Redis::Alfred.delete(key)
  rescue StandardError
    nil
  end

  def scan_auditor_redis_keys
    found = []
    if defined?($alfred) && $alfred.respond_to?(:with)
      $alfred.with do |conn|
        [DEDUP_REDIS_PREFIX, RATE_REDIS_PREFIX].each do |prefix|
          Array(conn.keys("#{prefix}:*")).each { |k| found << k } if conn.respond_to?(:keys)
        end
      end
    end
    found
  rescue StandardError
    []
  end

  def redis_hincrby(key, field, delta)
    if defined?(Redis::Alfred) && Redis::Alfred.respond_to?(:hincrby)
      Redis::Alfred.hincrby(key, field, delta)
    elsif defined?($alfred) && $alfred.respond_to?(:with)
      $alfred.with { |conn| conn.hincrby(key, field, delta) }
    end
  rescue StandardError
    nil
  end

  def fetch_redis_stats
    return {} unless defined?(Redis::Alfred)

    Redis::Alfred.hgetall(STATS_REDIS_KEY).to_h
  rescue StandardError
    {}
  end
end
# rubocop:enable Metrics/ModuleLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Style/GlobalVars
