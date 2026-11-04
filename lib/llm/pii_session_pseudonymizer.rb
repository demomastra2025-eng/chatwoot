# frozen_string_literal: true

require 'openssl'
require_relative 'pii_name_lexicon'
require_relative 'pii_shadow_auditor'

module Llm; end

# Reversible, tenant- and conversation-scoped server-side PII pseudonymization vault.
# Masks patient full names (FIO) and phone numbers into deterministic session tokens
# ([PII_NAME_XXXXXXXX], [PII_PHONE_XXXXXXXX]) before prompts/payloads leave OneLink,
# while preserving clinic doctors, services, medical terms, and detokenizing back
# strictly inside the same (account_id, scope_id) for built-in tools and customer replies.
# rubocop:disable Metrics/ModuleLength, Metrics/CollectionLiteralLength
module Llm::PiiSessionPseudonymizer
  THREAD_KEY = :llm_pii_session_pseudonymizer_scope
  REDIS_KEY_PREFIX = 'pii_vault:v1'
  REDIS_TTL_SECONDS = 7.days.to_i
  WHITELIST_TTL_SECONDS = 300
  TOKEN_PATTERN = /\[PII_(NAME|PHONE)_([0-9A-F]{8})\]/
  REDACTED_PLACEHOLDER = '[СКРЫТО]'

  KZ_CIS_PHONE_PATTERN = /(?<![0-9A-Za-z_])(?:\+7|8)[\s().-]*7\d{2}[\s().-]*\d{3}[\s().-]*\d{2}[\s().-]*\d{2}(?!\d)/
  INTL_PHONE_PATTERN = /(?<![0-9A-Za-z_])\+(?:996|998|992|993|994|374|375|380|90|971|1|44|49)[\s().-]*(?:\d[\s().-]*){8,12}\d(?!\d)/

  CYR_UPPER = 'А-ЯЁӘІҢҒҮҰҚӨҺ'
  CYR_LOWER = 'а-яёәіңғүұқөһ'
  CYR_WORD = "[#{CYR_UPPER}][#{CYR_LOWER}]{1,24}(?:-[#{CYR_UPPER}][#{CYR_LOWER}]{1,24})?".freeze
  CYR_CASED_WORD = "[#{CYR_UPPER}][#{CYR_UPPER}#{CYR_LOWER}]{1,24}(?:-[#{CYR_UPPER}#{CYR_LOWER}]{1,24})?".freeze
  CYR_ANYCASE_WORD = "[#{CYR_UPPER}#{CYR_LOWER}]{2,24}(?:-[#{CYR_UPPER}#{CYR_LOWER}]{2,24})?".freeze
  LAT_WORD = '[A-Z][a-z]{1,24}(?:-[A-Z][a-z]{1,24})?'
  LAT_ANYCASE_WORD = '[A-Za-z]{2,24}(?:-[A-Za-z]{2,24})?'

  SELF_INTRO_CYRILLIC = /
    (?<![[:alpha:]])
    (?:
      ((?i:меня\s+зовут|менің\s+атым|аты-жөнім|аты-жөні|фио|запишите\s+на\s+имя)\s*[:=-]?\s*)
      (#{CYR_ANYCASE_WORD}(?:\s+#{CYR_ANYCASE_WORD}){0,2})
      |
      ((?i:запишите\s+пациента|пациент(?:ка)?|клиент|емделуші|(?:здравствуйте|привет|сәлеметсіз\s+бе|салеметсиз\s+бе)\s*,?\s*я)\s*[:=-]?\s*)
      (#{CYR_CASED_WORD}(?:\s+#{CYR_CASED_WORD}){0,2})
    )
    (?![[:alpha:]])
  /xu

  SELF_INTRO_LATIN = /
    (?<![[:alpha:]])
    (?:
      ((?i:my\s+name\s+is|patient\s+name|full\s+name)\s*[:=-]?\s*)
      (#{LAT_ANYCASE_WORD}(?:\s+#{LAT_ANYCASE_WORD}){0,2})
      |
      ((?i:i\s+am)\s*[:=-]?\s*)
      (#{LAT_WORD}(?:\s+#{LAT_WORD}){0,2})
    )
    (?![[:alpha:]])
  /x

  CYRILLIC_FIO_CANDIDATE = /(?<![[:alpha:]\[])(#{CYR_WORD}(?:\s+#{CYR_WORD}){0,3})(?![[:alpha:]\]])/u
  LATIN_FIO_CANDIDATE = /(?<![[:alpha:]\[])(#{LAT_WORD}(?:\s+#{LAT_WORD}){0,3})(?![[:alpha:]\]])/

  SURNAME_OR_PATRONYMIC_CYR = /
    (?:ова|ева|ёва|ина|ов|ев|ёв|ин|ская|ский|цкая|цкий|кызы|қызы|улы|ұлы|
       ович|евич|овна|евна|ична|тегі|оглы|угли|ко|дзе|швили|ян)
    (?:а|у|ом|е|ой|ей|ым|ім|ға|ге|қа|ке|дан|ден|тан|тен)?\z
  /xiu

  SURNAME_OR_PATRONYMIC_LAT = /(?:ova|eva|ina|ov|ev|uly|kyzy|ovich|evna|skaya|skiy)\z/i

  DOCTOR_CONTEXT_SUFFIX = /
    (?:\A|[^[:alpha:]])
    (?:к|у|врач[ауеом]*|доктор[ауеом]*|специалист[ауеом]*|профессор[ауеом]*|дәрігер[гедің]*|маман[ғадр]*|
       doctor|dr\.?|prof\.?|physician|specialist|
       [а-яёәіңғүұқөһ-]+(?:лог|певт|иатр|ург|ортопед|окулист|стоматолог|акушер|узист|массажист)[ауеом]*|лор[уаом]*)
    \s+\z
  /xiu

  STATIC_STOPWORDS = %w[
    узи мрт кт экг эхо ээг фгдс лор оак оам пцр ифа осмс гобмп иин жсн фио
    алматы астана шымкент караганда актобе тараз павлодар семей атырау костанай
    кызылорда уральск актау туркестан кокшетау талдыкорган петропавловск экибастуз
    темиртау рудный жанаозен казахстан республика область город улица проспект микрорайон
    здравствуйте добрый доброе доброго день вечер утро ночи привет салеметсиз сәлеметсіз
    қайырлы күн кеш таң спасибо рахмет пожалуйста подскажите скажите запишите запись
    клиника центр медицинский медцентр больница поликлиника отделение кабинет филиал
    доктор врач специалист терапевт педиатр гинеколог уролог невролог кардиолог хирург
    эндокринолог дерматолог офтальмолог окулист стоматолог ортопед травматолог
    гастроэнтеролог аллерголог онколог маммолог проктолог психиатр психолог логопед
    массажист медсестра администратор оператор менеджер консультант ассистент
    прием приём первичный повторный консультация осмотр анализ анализы кровь крови
    брюшной полости щитовидной железы малого таза молочных желез почек печени сердца
    каспи kaspi whatsapp telegram instagram medelement onelink google apple
    понедельник вторник среда четверг пятница суббота воскресенье
    январь февраль март апрель май июнь июль август сентябрь октябрь ноябрь декабрь
    января февраля марта апреля мая июня июля августа сентября октября ноября декабря
    сегодня завтра послезавтра вчера утром днем вечером срочно цена стоимость оплата
    good morning afternoon evening hello clinic doctor dr prof physician specialist can see me appointment thank thanks
    дәрігер дәрігерге дәрігердің дәрігері маман маманға мамандар емхана клиникаға
    жазылу жазылайын жазыңызшы ертең ертеңге бүгін кешке таңертең сәлем салем қалайсыз
    бала баланы балаға баламды қызымды ұлымды мен менің маған біз бізге сіз сізге
    болады қашан қанша теңге бағасы адрес мекенжай
    это можно нужно хочу хотела хотел прошу помогите записаться отмена отменить
    перенести перенесите проверьте ребенок ребёнок ребенка ребёнка муж мужа жена жены
    мама маму папа папу сын сына дочь дочку пациент пациента клиент клиента
    имя фамилия отчество аты тегі жөні на в к по за до от из со и а но
  ].to_set.freeze

  IGNORED_CONTACT_NAMES = [
    '[удалено]', 'удалено', 'unresolved medelement patient', 'unknown', 'гость', 'клиент', 'пациент'
  ].to_set.freeze

  @whitelist_cache = {}
  @whitelist_mutex = Mutex.new

  module_function

  def current_scope = Thread.current[THREAD_KEY]
  def active? = current_scope.present?

  def clear_whitelist_cache!
    @whitelist_mutex.synchronize { @whitelist_cache.clear }
  end

  def with_scope(account_id:, scope_id:, conversation: nil, contact: nil, &)
    return yield if account_id.blank? || scope_id.blank?

    previous = Thread.current[THREAD_KEY]
    return reuse_existing_scope(previous, conversation, contact, &) if same_scope?(previous, account_id, scope_id)

    activate_new_scope(previous, account_id, scope_id, conversation, contact, &)
  end

  def reuse_existing_scope(scope, conversation, contact)
    seed_scope!(scope, conversation: conversation, contact: contact) if conversation || contact
    yield
  end

  def activate_new_scope(previous, account_id, scope_id, conversation, contact)
    Thread.current[THREAD_KEY] = build_scope(
      account_id: account_id.to_i, scope_id: scope_id.to_s, conversation: conversation, contact: contact
    )
    yield
  ensure
    Thread.current[THREAD_KEY] = previous
  end

  def snapshot_scope
    scope = current_scope
    return nil if scope.blank?

    {
      account_id: scope[:account_id],
      scope_id: scope[:scope_id],
      memory: scope[:memory].dup,
      whitelist: scope[:whitelist],
      seeded_names: scope[:seeded_names].dup,
      seeded_phones: scope[:seeded_phones].dup
    }
  end

  def adopt_scope(snapshot)
    return yield if snapshot.blank?

    previous = Thread.current[THREAD_KEY]
    Thread.current[THREAD_KEY] = {
      account_id: snapshot[:account_id],
      scope_id: snapshot[:scope_id],
      memory: snapshot[:memory].dup,
      whitelist: snapshot[:whitelist] || empty_whitelist,
      seeded_names: Array(snapshot[:seeded_names]).dup,
      seeded_phones: Array(snapshot[:seeded_phones]).dup
    }
    yield
  ensure
    Thread.current[THREAD_KEY] = previous if snapshot.present?
  end

  def tokenize_name(raw_value)
    cleaned = raw_value.to_s.squish
    return raw_value if !active? || cleaned.blank?

    register_token('NAME', normalize_name_key(cleaned), cleaned)
  end

  def tokenize_phone(raw_value)
    cleaned = raw_value.to_s.strip
    return raw_value if !active? || cleaned.blank?

    canonical = canonical_phone(cleaned)
    return raw_value if canonical.blank?

    register_token('PHONE', canonical, canonical)
  end

  def mask_text(text)
    return text unless active? && text.is_a?(String) && text.present?

    scope = current_scope
    out = mask_phones(text, scope)
    out = mask_seeded_names(out, scope)
    out = mask_self_introductions(out, scope)
    masked = mask_fio_phrases(out, scope)
    Llm::PiiShadowAuditor.record_mask_pass!(text, masked, account_id: scope[:account_id]) if defined?(Llm::PiiShadowAuditor)
    masked
  end

  def unmask_text(text)
    return text unless active? && text.is_a?(String) && text.include?('[PII_')

    scope = current_scope
    s_key = scope_key(scope)
    text.gsub(TOKEN_PATTERN) do |full|
      kind = Regexp.last_match(1)
      token_id = Regexp.last_match(2)
      resolve_token(scope, s_key, kind, token_id) || full
    end
  end

  def unmask_customer_text(text)
    return strip_tokens(text) unless active?
    return text unless text.is_a?(String) && text.include?('[PII_')

    unmasked = unmask_text(text)
    strip_tokens(unmasked)
  end

  def unmask_deep(value)
    return value unless active?

    case value
    when String then unmask_text(value)
    when Array then value.map { |item| unmask_deep(item) }
    when Hash then value.transform_values { |item| unmask_deep(item) }
    else value
    end
  end

  def strip_tokens(text, replacement = REDACTED_PLACEHOLDER)
    text.is_a?(String) && text.include?('[PII_') ? text.gsub(TOKEN_PATTERN, replacement) : text
  end

  def purge_scope!(account_id:, scope_id:)
    return 0 if account_id.blank? || scope_id.blank? || !defined?(Redis::Alfred)

    pattern = "#{REDIS_KEY_PREFIX}:#{scope_digest("acct:#{account_id.to_i}:#{scope_id}")}:*"
    keys = []
    Redis::Alfred.scan_each(match: pattern) { |key| keys << key }
    keys.sum { |key| Redis::Alfred.delete(key).to_i }
  rescue StandardError
    0
  end

  def phone_like_value?(value)
    return false unless value.is_a?(String) || value.is_a?(Integer)

    canonical_phone(value.to_s).present?
  end

  def build_scope(account_id:, scope_id:, conversation:, contact:)
    scope = {
      account_id: account_id,
      scope_id: scope_id,
      memory: {},
      whitelist: clinic_whitelist_for(account_id),
      seeded_names: [],
      seeded_phones: []
    }
    seed_scope!(scope, conversation: conversation, contact: contact)
    scope
  end

  def seed_scope!(scope, conversation: nil, contact: nil)
    seed_contacts_list!(scope, [contact, conversation&.try(:contact)])
    seed_conversation_appointments!(scope, conversation) if conversation.respond_to?(:scheduling_appointments)
    finalize_seeded_lists!(scope)
  rescue StandardError
    scope
  end

  def seed_contacts_list!(scope, raw_contacts)
    raw_contacts.compact.uniq(&:id).each { |item| seed_contact!(scope, item) }
  end

  def finalize_seeded_lists!(scope)
    scope[:seeded_names] = scope[:seeded_names].uniq.sort_by { |n| -n.length }
    scope[:seeded_phones] = scope[:seeded_phones].uniq.sort_by { |p| -p.length }
  end

  def seed_contact!(scope, contact)
    seed_contact_phones!(scope, contact)
    seed_contact_names!(scope, contact)
  end

  def seed_contact_phones!(scope, contact)
    seed_phone_candidate!(scope, contact.try(:phone_number))
    Array(contact.try(:custom_attributes).to_h['secondary_phones']).each { |p| seed_phone_candidate!(scope, p) }
    return unless defined?(ContactPhone) && contact.try(:id).present?

    ContactPhone.where(contact_id: contact.id).pluck(:phone_number).each { |p| seed_phone_candidate!(scope, p) }
  end

  def seed_contact_names!(scope, contact)
    parts = extract_contact_name_parts(contact)
    contact_name_variants(parts).each { |phrase| seed_name_candidate!(scope, phrase, allow_single: true) }
    parts.each_value { |part| seed_name_candidate!(scope, part, allow_single: true) }
  end

  def extract_contact_name_parts(contact)
    attrs = contact.try(:custom_attributes).to_h
    {
      first: contact.try(:name).to_s.squish,
      last: contact.try(:last_name).to_s.squish,
      middle: contact.try(:middle_name).to_s.squish,
      med_first: attrs['medelement_first_name'].to_s.squish,
      med_last: attrs['medelement_last_name'].to_s.squish
    }
  end

  def contact_name_variants(parts)
    [
      [parts[:last], parts[:first], parts[:middle]].compact_blank.join(' '),
      [parts[:first], parts[:last], parts[:middle]].compact_blank.join(' '),
      [parts[:first], parts[:last]].compact_blank.join(' '),
      [parts[:last], parts[:first]].compact_blank.join(' '),
      [parts[:med_last], parts[:med_first]].compact_blank.join(' '),
      [parts[:med_first], parts[:med_last]].compact_blank.join(' ')
    ]
  end

  def seed_conversation_appointments!(scope, conversation)
    conversation.scheduling_appointments.limit(10).pluck(
      :client_name, :client_first_name, :client_last_name, :client_middle_name, :client_phone
    ).each do |c_name, c_first, c_last, c_mid, c_phone|
      seed_phone_candidate!(scope, c_phone)
      [c_name, [c_last, c_first, c_mid].compact_blank.join(' '), c_first, c_last].each do |candidate|
        seed_name_candidate!(scope, candidate, allow_single: true)
      end
    end
  end

  def seed_phone_candidate!(scope, raw_phone)
    canonical = canonical_phone(raw_phone)
    return if canonical.blank?

    register_in_scope(scope, 'PHONE', canonical, canonical)
    scope[:seeded_phones] << canonical
    raw_clean = raw_phone.to_s.strip
    scope[:seeded_phones] << raw_clean if raw_clean.length >= 10
  end

  def seed_name_candidate!(scope, raw_name, allow_single: false)
    cleaned = raw_name.to_s.squish
    return if invalid_seeded_name_string?(cleaned)

    words = cleaned.scan(/[[:alpha:]-]+/)
    return unless seedable_name_words?(words, scope[:whitelist], allow_single: allow_single)

    register_in_scope(scope, 'NAME', normalize_name_key(cleaned), cleaned)
    scope[:seeded_names] << cleaned
  end

  def invalid_seeded_name_string?(cleaned)
    cleaned.length < 3 || IGNORED_CONTACT_NAMES.include?(cleaned.downcase) ||
      cleaned.match?(/\d/) || cleaned.include?('[PII_') || cleaned.include?('[IIN_')
  end

  def seedable_name_words?(words, whitelist, allow_single:)
    return false if words.size < (allow_single ? 1 : 2)
    return seedable_single_word?(words.first, whitelist) if words.one?

    !words.all? { |w| stopword_or_service_word?(w, whitelist) } && !matches_clinic_doctor?(words, whitelist)
  end

  def seedable_single_word?(word, whitelist)
    word.length >= 3 && !stopword_or_service_word?(word, whitelist)
  end

  def mask_phones(text, scope)
    out = text.dup
    scope[:seeded_phones].each do |seeded_phone|
      next unless out.include?(seeded_phone)

      token = register_in_scope(scope, 'PHONE', canonical_phone(seeded_phone), canonical_phone(seeded_phone))
      out.gsub!(/(?<!\d)#{Regexp.escape(seeded_phone)}(?!\d)/, token)
    end
    [KZ_CIS_PHONE_PATTERN, INTL_PHONE_PATTERN].each do |pattern|
      out.gsub!(pattern) do |match|
        canonical = canonical_phone(match)
        canonical.present? ? register_in_scope(scope, 'PHONE', canonical, canonical) : match
      end
    end
    out
  end

  def mask_seeded_names(text, scope)
    return text if scope[:seeded_names].empty?

    out = text.dup
    scope[:seeded_names].each do |seeded|
      pattern = seeded_name_pattern(seeded)
      next unless out.match?(pattern)

      out = out.gsub(pattern) do |matched|
        prefix = Regexp.last_match.pre_match.last(32)
        if doctor_context?(prefix)
          matched
        else
          register_in_scope(scope, 'NAME', normalize_name_key(seeded), seeded)
        end
      end
    end
    out
  end

  # Ephemeral patterns are scoped only to the active thread scope; no global plaintext cache is kept.
  @seeded_pattern_cache = {}.freeze

  def seeded_name_pattern(seeded)
    words = seeded.scan(/[[:alpha:]-]+/)
    if words.empty?
      /(?<![[:alpha:]])#{Regexp.escape(seeded)}(?![[:alpha:]])/iu
    else
      flex_parts = words.map do |w|
        stem = Llm::PiiNameLexicon.stem_word(normalize_word(w))
        stem.length >= 3 ? "#{Regexp.escape(stem)}[[:alpha:]]{0,4}" : Regexp.escape(w)
      end
      /(?<![[:alpha:]\[])#{flex_parts.join('\s+')}(?![[:alpha:]\]])/iu
    end
  end

  def mask_self_introductions(text, scope)
    out = replace_self_intro_pattern(text, SELF_INTRO_CYRILLIC, scope)
    replace_self_intro_pattern(out, SELF_INTRO_LATIN, scope)
  end

  def replace_self_intro_pattern(text, pattern, scope)
    text.gsub(pattern) do |full|
      prefix = Regexp.last_match(1) || Regexp.last_match(3)
      captured_name = Regexp.last_match(2) || Regexp.last_match(4)
      words = captured_name.to_s.split(/\s+/)
      lead, core, tail = trim_boundary_stopwords(words, scope[:whitelist])
      if core.empty? || lead.any?
        full
      else
        core_str = core.join(' ')
        tail_str = tail.empty? ? '' : " #{tail.join(' ')}"
        "#{prefix}#{register_in_scope(scope, 'NAME', normalize_name_key(core_str), core_str)}#{tail_str}"
      end
    end
  end

  def mask_fio_phrases(text, scope)
    out = text.gsub(CYRILLIC_FIO_CANDIDATE) do |phrase|
      replace_fio_candidate(phrase, Regexp.last_match.pre_match.last(32), scope, SURNAME_OR_PATRONYMIC_CYR)
    end

    out.gsub(LATIN_FIO_CANDIDATE) do |phrase|
      replace_fio_candidate(phrase, Regexp.last_match.pre_match.last(32), scope, SURNAME_OR_PATRONYMIC_LAT)
    end
  end

  def replace_fio_candidate(phrase, prefix, scope, suffix_pattern)
    whitelist = scope[:whitelist]
    words = phrase.split(/\s+/)
    lead, core, tail = trim_boundary_stopwords(words, whitelist)
    return phrase if core.empty?

    eff_prefix = lead.empty? ? prefix : "#{prefix}#{lead.join(' ')} ".last(32)
    core_phrase = core.join(' ')
    return phrase unless valid_fio_phrase?(core_phrase, eff_prefix, whitelist, suffix_pattern)

    token = register_in_scope(scope, 'NAME', normalize_name_key(core_phrase), core_phrase)
    lead_str = lead.empty? ? '' : "#{lead.join(' ')} "
    tail_str = tail.empty? ? '' : " #{tail.join(' ')}"
    "#{lead_str}#{token}#{tail_str}"
  end

  def trim_boundary_stopwords(words, whitelist)
    idx_start = 0
    idx_start += 1 while idx_start < words.size && stopword_or_service_word?(words[idx_start], whitelist)
    idx_end = words.size - 1
    idx_end -= 1 while idx_end >= idx_start && stopword_or_service_word?(words[idx_end], whitelist)
    return [words, [], []] if idx_start > idx_end

    [words[0...idx_start], words[idx_start..idx_end], words[(idx_end + 1)..] || []]
  end

  def valid_fio_phrase?(phrase, prefix, whitelist, suffix_pattern)
    return false if doctor_context?(prefix)

    words = phrase.split(/\s+/)
    return valid_single_person_word?(words.first, whitelist) if words.one?

    valid_multiword_fio?(words, whitelist, suffix_pattern)
  end

  def valid_multiword_fio?(words, whitelist, suffix_pattern)
    return false unless words.size.between?(2, 3)
    return false if words.any? { |w| stopword_or_service_word?(w, whitelist) }
    return false if matches_clinic_doctor?(words, whitelist)

    multiword_person_match?(words, suffix_pattern)
  end

  def multiword_person_match?(words, suffix_pattern)
    return words.all? { |w| Llm::PiiNameLexicon.known_person_name_word?(w) } unless words.any? { |w| w.match?(suffix_pattern) }

    words.count { |w| w.match?(suffix_pattern) || Llm::PiiNameLexicon.known_person_name_word?(w) } >= words.size - 1
  end

  def valid_single_person_word?(word, whitelist)
    return false if whitelisted_word?(word, whitelist)

    Llm::PiiNameLexicon.unambiguous_single_name?(word, stopwords: STATIC_STOPWORDS)
  end

  def doctor_context?(prefix)
    prefix.to_s.match?(DOCTOR_CONTEXT_SUFFIX)
  end

  def stopword_or_service_word?(word, whitelist)
    norm = normalize_word(word)
    return true if norm.length < 2
    return true if STATIC_STOPWORDS.include?(norm) || STATIC_STOPWORDS.include?(word_stem(norm))

    service_words = whitelist.is_a?(Hash) ? whitelist[:service_words] : whitelist
    word_in_set?(norm, service_words)
  end

  def matches_clinic_doctor?(words, whitelist)
    return false unless whitelist.is_a?(Hash)

    Array(whitelist[:doctor_sets]).any? do |doc_entry|
      required = [doc_entry[:word_count], 2].min
      required.positive? && words.count { |w| word_in_set?(normalize_word(w), doc_entry[:terms]) } >= required
    end
  end

  def whitelisted_word?(word, whitelist)
    return false if whitelist.blank?

    norm = normalize_word(word)
    all_words = whitelist.is_a?(Hash) ? whitelist[:all_words] : whitelist
    word_in_set?(norm, all_words)
  end

  def word_in_set?(norm, set)
    set.present? && (set.include?(norm) || set.include?(word_stem(norm)))
  end

  def empty_whitelist
    { service_words: Set.new.freeze, doctor_sets: [].freeze, all_words: Set.new.freeze }.freeze
  end

  def clinic_whitelist_for(account_id)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @whitelist_mutex.synchronize do
      cached = @whitelist_cache[account_id]
      return cached[:data] if cached && cached[:expires_at] > now
    end

    data = load_clinic_whitelist(account_id)
    @whitelist_mutex.synchronize do
      @whitelist_cache[account_id] = { data: data, expires_at: now + WHITELIST_TTL_SECONDS }
    end
    data
  rescue StandardError
    empty_whitelist
  end

  def load_clinic_whitelist(account_id)
    service_words = Set.new
    fetch_clinic_non_doctor_names(account_id).each { |entry| add_whitelist_words!(service_words, entry) }
    doctor_sets = build_doctor_whitelist_sets(account_id)
    all_words = (service_words + doctor_sets.flat_map { |d| d[:terms].to_a }).to_set
    { service_words: service_words.freeze, doctor_sets: doctor_sets.freeze, all_words: all_words.freeze }.freeze
  end

  def fetch_clinic_non_doctor_names(account_id)
    names = []
    names << Account.where(id: account_id).pick(:name) if defined?(Account)
    names.concat(Scheduling::Service.where(account_id: account_id).pluck(:name)) if defined?(Scheduling::Service)
    names.concat(Captain::Assistant.where(account_id: account_id).pluck(:name)) if defined?(Captain::Assistant)
    names.compact_blank
  end

  def build_doctor_whitelist_sets(account_id)
    return [] unless defined?(Scheduling::Resource)

    Scheduling::Resource.where(account_id: account_id).pluck(:name).compact_blank.filter_map do |doc_name|
      raw_tokens = doc_name.to_s.scan(/[[:alpha:]]{2,}/)
      next if raw_tokens.empty?

      terms = Set.new
      add_whitelist_words!(terms, doc_name)
      { word_count: raw_tokens.size, terms: terms.freeze }.freeze
    end
  end

  def add_whitelist_words!(words, entry)
    entry.to_s.scan(/[[:alpha:]]{2,}/).each do |word|
      norm = normalize_word(word)
      words << norm
      stem = word_stem(norm)
      words << stem if stem.length >= 4
    end
  end

  def normalize_word(word)
    word.to_s.unicode_normalize(:nfkc).downcase
  end

  def word_stem(norm_word)
    return norm_word if norm_word.length < 5

    norm_word.sub(/(?:овой|евой|иной|ому|ему|ой|ей|ом|ем|ами|ями|ах|ях|у|ю|а|я|е|ы|и)\z/u, '')
  end

  def normalize_name_key(value)
    value.to_s.unicode_normalize(:nfkc).squish.downcase
  end

  def canonical_phone(raw_value)
    str = raw_value.to_s.strip
    return nil if str.blank?

    digits = str.gsub(/\D/, '')
    return "+7#{digits[1..]}" if kz_eleven_digit_phone?(digits)
    return "+#{digits}" if str.start_with?('+') && digits.length.between?(10, 15)

    normalize_via_contact_phone_normalizer(str, digits)
  rescue StandardError
    nil
  end

  def kz_eleven_digit_phone?(digits)
    digits.length == 11 && digits.start_with?('77', '87')
  end

  def normalize_via_contact_phone_normalizer(str, digits)
    return nil unless defined?(Contacts::PhoneNumberNormalizer) && digits.length.between?(10, 15)

    normalized = Contacts::PhoneNumberNormalizer.normalize(str)
    normalized if normalized.present? && normalized.start_with?('+')
  end

  def register_token(kind, canonical_key, original_value)
    register_in_scope(current_scope, kind, canonical_key, original_value)
  end

  def register_in_scope(scope, kind, canonical_key, original_value)
    s_key = scope_key(scope)
    token_id = hmac_token_id(s_key, kind, canonical_key)
    compound_id = "#{kind}:#{token_id}"
    unless scope[:memory].key?(compound_id)
      scope[:memory][compound_id] = original_value
      write_redis_entry(s_key, kind, token_id, original_value)
    end
    "[PII_#{kind}_#{token_id}]"
  end

  def same_scope?(previous, account_id, scope_id)
    previous.present? && previous[:account_id] == account_id.to_i && previous[:scope_id] == scope_id.to_s
  end

  def scope_key(scope) = "acct:#{scope[:account_id]}:#{scope[:scope_id]}"

  def hmac_token_id(s_key, kind, canonical_key)
    OpenSSL::HMAC.hexdigest('SHA256', secret_material, "pii_token:v1:#{s_key}:#{kind}:#{canonical_key}")[0, 8].upcase
  end

  def scope_digest(s_key)
    OpenSSL::HMAC.hexdigest('SHA256', secret_material, "pii_scope:v1:#{s_key}")[0, 24]
  end

  def redis_key(s_key, kind, token_id)
    "#{REDIS_KEY_PREFIX}:#{scope_digest(s_key)}:#{kind}:#{token_id}"
  end

  def secret_material
    key = Rails.application.secret_key_base.to_s
    return key if key.present?
    raise 'Rails.application.secret_key_base is required for Llm::PiiSessionPseudonymizer' if Rails.env.production?

    'onelink-nonprod-pii-session-pseudonymizer-key'
  end

  def encryptor_for(s_key)
    key = OpenSSL::HMAC.digest('SHA256', secret_material, "pii_vault_enc:v1:#{s_key}")
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm')
  end

  def write_redis_entry(s_key, kind, token_id, value)
    return unless defined?(Redis::Alfred)

    encrypted = encryptor_for(s_key).encrypt_and_sign(value.to_s, purpose: "#{s_key}:#{kind}:#{token_id}")
    Redis::Alfred.set(redis_key(s_key, kind, token_id), encrypted, ex: REDIS_TTL_SECONDS)
  rescue StandardError
    nil
  end

  def resolve_token(scope, s_key, kind, token_id)
    compound_id = "#{kind}:#{token_id}"
    scope[:memory][compound_id] || read_redis_entry(scope, s_key, kind, token_id)
  end

  def read_redis_entry(scope, s_key, kind, token_id)
    return nil unless defined?(Redis::Alfred)

    encrypted = Redis::Alfred.get(redis_key(s_key, kind, token_id))
    return nil if encrypted.blank?

    decrypted = encryptor_for(s_key).decrypt_and_verify(encrypted, purpose: "#{s_key}:#{kind}:#{token_id}")
    decrypted.is_a?(String) && decrypted.present? ? (scope[:memory]["#{kind}:#{token_id}"] = decrypted) : nil
  rescue StandardError
    nil
  end

  private_class_method :build_scope, :seed_scope!, :seed_contact!, :seed_conversation_appointments!,
                       :seed_phone_candidate!, :seed_name_candidate!, :mask_phones, :mask_seeded_names,
                       :mask_self_introductions, :mask_fio_phrases, :replace_fio_candidate, :trim_boundary_stopwords,
                       :seeded_name_pattern, :valid_fio_phrase?, :valid_multiword_fio?, :valid_single_person_word?, :doctor_context?,
                       :stopword_or_service_word?, :matches_clinic_doctor?, :whitelisted_word?, :word_in_set?,
                       :empty_whitelist, :clinic_whitelist_for, :load_clinic_whitelist,
                       :fetch_clinic_non_doctor_names, :build_doctor_whitelist_sets,
                       :normalize_word, :word_stem, :normalize_name_key, :canonical_phone, :register_token,
                       :register_in_scope, :same_scope?, :scope_key, :hmac_token_id, :scope_digest, :redis_key,
                       :secret_material, :encryptor_for, :write_redis_entry, :resolve_token, :read_redis_entry
end
# rubocop:enable Metrics/ModuleLength, Metrics/CollectionLiteralLength
