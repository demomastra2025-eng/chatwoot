# frozen_string_literal: true

class Captain::Llm::FaqMergeSynthesizerService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  MAX_OUTPUT_TOKENS = 2048

  def initialize(entries, account_id: nil, use_llm: true)
    super()
    @entries = Array(entries)
    @account_id = account_id
    @use_llm = use_llm
  end

  def synthesize
    fallback = deterministic_merge
    return fallback if !@use_llm || @entries.size < 2 || !llm_configured?

    llm_result = generate_via_llm
    return fallback if llm_result.blank?

    ensure_no_lost_facts(llm_result, fallback)
  rescue StandardError => e
    Rails.logger.warn("[Captain::FaqMergeSynthesizer] Fallback to deterministic merge: #{e.class}: #{e.message}")
    fallback
  end

  def deterministic_merge
    questions = @entries.map { |entry| extract_field(entry, :question) }.reject(&:blank?)
    answers = @entries.map { |entry| extract_field(entry, :answer) }.reject(&:blank?)

    {
      question: select_canonical_question(questions),
      answer: merge_answers_losslessly(answers)
    }
  end

  private

  def llm_configured?
    ENV['OPENAI_API_KEY'].present? || InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value.present?
  end

  def generate_via_llm
    response = instrument_llm_call(instrumentation_params) do
      llm_chat = apply_chat_features(chat, schema: Captain::Llm::Schemas::FaqCollection)
                 .with_instructions(system_prompt).with_params(max_tokens: MAX_OUTPUT_TOKENS)
      ask_chat(llm_chat, user_prompt)
    end
    parse_first_faq(response.content)
  end

  def parse_first_faq(content)
    return unless content.is_a?(Hash)

    first = Array(content.with_indifferent_access[:faqs]).first&.with_indifferent_access
    return if first.blank? || first[:question].blank? || first[:answer].blank?

    { question: first[:question].to_s.strip, answer: first[:answer].to_s.strip }
  end

  def ensure_no_lost_facts(llm_result, fallback)
    source_numbers = fallback[:answer].scan(/\d{2,}/).uniq
    llm_numbers = llm_result[:answer].scan(/\d{2,}/).uniq
    missing_numbers = source_numbers - llm_numbers
    return llm_result if missing_numbers.empty?

    missing_clauses = split_clauses(fallback[:answer]).select do |clause|
      missing_numbers.any? { |num| clause.include?(num) }
    end
    return llm_result if missing_clauses.empty?

    {
      question: llm_result[:question],
      answer: ([llm_result[:answer]] + missing_clauses).join(' ')
    }
  end

  def select_canonical_question(questions)
    return '' if questions.empty?

    questions.first
  end

  def merge_answers_losslessly(answers)
    return '' if answers.empty?
    return answers.first if answers.one?

    if answers.any? { |ans| ans.match?(/\bKZ:\s*/i) }
      merge_bilingual_answers(answers)
    else
      merge_text_blocks(answers)
    end
  end

  def merge_bilingual_answers(answers)
    ru_parts = []
    kz_parts = []

    answers.each do |ans|
      ru, kz = ans.to_s.split(/\bKZ:\s*/i, 2)
      ru_clean = ru.to_s.sub(/\ARU:\s*/i, '').strip
      ru_parts << ru_clean if ru_clean.present?
      kz_parts << kz.to_s.strip if kz.present?
    end

    merged_ru = merge_text_blocks(ru_parts)
    merged_kz = merge_text_blocks(kz_parts)
    return "RU: #{merged_ru}\nKZ: #{merged_kz}" if merged_kz.present?

    merged_ru
  end

  def merge_text_blocks(blocks)
    seen_norms = []
    kept_clauses = []

    blocks.flat_map { |block| split_clauses(block) }.each do |clause|
      norm = normalize_clause(clause)
      next if norm.blank? || clause_redundant?(norm, seen_norms, kept_clauses, clause)

      seen_norms << norm
      kept_clauses << clause
    end

    kept_clauses.join(' ')
  end

  def clause_redundant?(norm, seen_norms, kept_clauses, clause)
    seen_norms.each_with_index do |existing_norm, idx|
      return true if existing_norm == norm || existing_norm.include?(norm)
      next unless norm.include?(existing_norm)

      seen_norms[idx] = norm
      kept_clauses[idx] = clause
      return true
    end
    false
  end

  def split_clauses(text)
    text.to_s.split(/(?<=[.?!;])\s+|\n+/).map(&:strip).reject(&:blank?)
  end

  def normalize_clause(text)
    text.to_s.unicode_normalize(:nfkc).downcase.tr('ё', 'е').gsub(/[[:punct:]\s]+/, ' ').strip
  end

  def extract_field(entry, key)
    entry.respond_to?(key) ? entry.public_send(key).to_s.strip : entry[key].to_s.strip
  end

  def system_prompt
    <<~PROMPT.strip
      You are a medical and enterprise knowledge base canonicalizer.
      Merge multiple duplicate FAQ entries about the same topic into a SINGLE comprehensive, non-redundant FAQ entry.
      CRITICAL RULES:
      1. Preserve 100% of factual details from all input entries: prices, doctor names, cabinet numbers, preparation rules, age limits, and contraindications.
      2. Remove duplicate sentences and phrasing.
      3. Keep the original language(s) of the entries (including RU:/KZ: bilingual format if present).
      4. Return exactly 1 merged FAQ entry in the `faqs` array.
    PROMPT
  end

  def user_prompt
    @entries.each_with_index.map do |entry, index|
      "Entry ##{index + 1}:\nQuestion: #{extract_field(entry, :question)}\nAnswer: #{extract_field(entry, :answer)}"
    end.join("\n\n---\n\n")
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.faq_merge_synthesizer',
      model: model,
      temperature: 0.1,
      feature_name: 'faq_merge_synthesizer',
      account_id: @account_id,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: user_prompt }
      ]
    }
  end

  def llm_feature_key
    :assistant
  end

  def llm_model_account
    return if @account_id.blank?

    @llm_model_account ||= Account.find_by(id: @account_id)
  end
end
