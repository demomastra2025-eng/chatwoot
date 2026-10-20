# frozen_string_literal: true

class Captain::Knowledge::FaqMergerService
  include Captain::Knowledge::Graph::Lexicon

  EMBEDDING_DUPLICATE_DISTANCE = 0.14
  EXTRA_FILLER_WORDS = %w[нужен нужна нужно нужны перед после ли же бы].freeze

  def self.merge_records!(records, use_llm: true)
    new(records.first&.account).merge_records!(records, use_llm: use_llm)
  end

  def self.canonicalize_on_approve!(record, use_llm: true)
    new(record.account).canonicalize_on_approve!(record, use_llm: use_llm)
  end

  def self.approve_and_canonicalize_batch!(records, use_llm: true)
    list = Array(records).compact
    return [] if list.empty?

    new(list.first.account).approve_and_canonicalize_batch!(list, use_llm: use_llm)
  end

  def self.deduplicate_scope!(scope, use_llm: true)
    records = scope.to_a
    return { merged_clusters_count: 0, removed_duplicates_count: 0, canonical_records: [] } if records.empty?

    new(records.first.account).deduplicate_records!(records, use_llm: use_llm)
  end

  def initialize(account)
    @account = account
  end

  def merge_records!(records, use_llm: true)
    sorted = sort_for_canonical(records)
    raise ArgumentError, 'At least one FAQ record is required' if sorted.empty?
    return sorted.first if sorted.one?

    canonical = sorted.first
    duplicates = sorted.drop(1)
    synthesized = Captain::Llm::FaqMergeSynthesizerService.new(
      sorted, account_id: @account&.id, use_llm: use_llm
    ).synthesize

    apply_merge_transaction!(canonical, duplicates, synthesized, sorted)
  end

  def canonicalize_on_approve!(record, use_llm: true)
    duplicates = find_approved_duplicates_for(record)
    if duplicates.any?
      merge_records!([*duplicates, record], use_llm: use_llm)
    else
      record.update!(status: 'approved') unless record.approved?
      record
    end
  end

  def approve_and_canonicalize_batch!(records, use_llm: true)
    ordered_ids = records.sort_by(&:id).map(&:id)
    results = []

    ordered_ids.each do |id|
      rec = Captain::AssistantResponse.find_by(id: id, account_id: @account.id)
      next unless rec

      results << canonicalize_on_approve!(rec, use_llm: use_llm)
    end

    results.uniq(&:id)
  end

  def deduplicate_records!(records, use_llm: true)
    clusters = build_duplicate_clusters(records)
    merged_clusters_count = 0
    removed_count = 0
    canonicals = []

    clusters.each do |cluster|
      if cluster.size > 1
        merged_clusters_count += 1
        removed_count += cluster.size - 1
        canonicals << merge_records!(cluster, use_llm: use_llm)
      else
        canonicals << cluster.first
      end
    end

    {
      merged_clusters_count: merged_clusters_count,
      removed_duplicates_count: removed_count,
      canonical_records: canonicals
    }
  end

  def find_approved_duplicates_for(record)
    scope = Captain::AssistantResponse
            .approved
            .where(account_id: record.account_id, assistant_id: record.assistant_id, visibility: record.visibility)
            .where.not(id: record.id)

    candidates = scope.order(:id).to_a
    semantic_ids = semantic_duplicate_ids(record, scope)
    candidates.select { |candidate| duplicate_pair?(record, candidate, semantic_ids) }
  end

  private

  def apply_merge_transaction!(canonical, duplicates, synthesized, all_records)
    merged_grant_ids = all_records.flat_map(&:allowed_assistant_ids).uniq

    ActiveRecord::Base.transaction do
      attrs = {
        question: synthesized[:question].presence || canonical.question,
        answer: synthesized[:answer].presence || canonical.answer,
        status: 'approved'
      }
      attrs[:allowed_assistant_ids] = merged_grant_ids if canonical.visibility == 'personal' && merged_grant_ids.any?
      canonical.update!(attrs)
      duplicates.each(&:destroy!)
    end

    canonical.reload
  end

  def sort_for_canonical(records)
    Array(records).compact.uniq(&:id).sort_by do |rec|
      [rec.approved? ? 0 : 1, rec.id || Float::INFINITY]
    end
  end

  def build_duplicate_clusters(records)
    sorted = sort_for_canonical(records)
    visited = {}
    clusters = []

    sorted.each do |rec|
      next if visited[rec.id]

      visited[rec.id] = true
      cluster = [rec]
      sorted.each do |other|
        next if visited[other.id] || !same_partition?(rec, other)
        next unless duplicate_pair?(rec, other, Set.new)

        visited[other.id] = true
        cluster << other
      end
      clusters << cluster
    end

    clusters
  end

  def same_partition?(first, second)
    first.account_id == second.account_id &&
      first.assistant_id == second.assistant_id &&
      first.visibility == second.visibility
  end

  def semantic_duplicate_ids(record, scope)
    return Set.new if record.embedding.blank?

    scope.nearest_neighbors(:embedding, record.embedding, distance: 'cosine')
         .limit(5)
         .select { |neighbor| neighbor.neighbor_distance.to_f <= EMBEDDING_DUPLICATE_DISTANCE }
         .to_set(&:id)
  rescue StandardError
    Set.new
  end

  def duplicate_pair?(first, second, semantic_ids)
    return false if conflicting_numbers?(first.question, second.question)
    return false if negated?(first.question) != negated?(second.question)
    return true if normalize_question(first.question) == normalize_question(second.question)

    same_subject_and_intent?(first.question, second.question, semantic_ids.include?(second.id))
  end

  def same_subject_and_intent?(first_question, second_question, is_semantic_neighbor)
    subj1, intents1 = decompose_question(first_question)
    subj2, intents2 = decompose_question(second_question)
    return false if subj1.empty? || subj2.empty?
    return false unless subj1 == subj2

    intents1 == intents2 || is_semantic_neighbor
  end

  def decompose_question(question)
    words = question.to_s.downcase.tr('ё', 'е').scan(/[\p{Alnum}]+/)
    meaningful = words.reject { |w| QUERY_FILLER_WORDS.include?(w) || EXTRA_FILLER_WORDS.include?(w) || w.length < 3 }
    intents = Set.new
    subject_words = []

    meaningful.each do |word|
      matched_intents = INTENT_RULES.select { |_k, rule| word.match?(rule[:pattern]) }.keys
      if matched_intents.any?
        intents.merge(matched_intents)
      else
        subject_words << word
      end
    end

    [Captain::Knowledge::Graph::Stemmer.extract_stems(*subject_words).to_set, intents]
  end

  def negated?(question)
    question.to_s.downcase.tr('ё', 'е').scan(/[\p{Alnum}]+/).intersect?(NEGATION_TOKENS)
  end

  def conflicting_numbers?(first_question, second_question)
    nums1 = first_question.to_s.scan(/\d+/).uniq.sort
    nums2 = second_question.to_s.scan(/\d+/).uniq.sort
    return false if nums1.empty? && nums2.empty?

    nums1 != nums2
  end

  def normalize_question(text)
    text.to_s.unicode_normalize(:nfkc).downcase.tr('ё', 'е').gsub(/[[:punct:]\s]+/, ' ').strip
  end
end
