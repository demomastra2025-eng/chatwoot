# == Schema Information
#
# Table name: captain_assistant_responses
#
#  id                :bigint           not null, primary key
#  answer            :text             not null
#  documentable_type :string
#  edited            :boolean          default(FALSE), not null
#  embedding         :vector(1536)
#  question          :string           not null
#  status            :integer          default("approved"), not null
#  visibility        :integer          default("general"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  assistant_id      :bigint
#  document_chunk_id :bigint
#  documentable_id   :bigint
#
# Indexes
#
#  idx_cap_asst_resp_on_documentable                       (documentable_id,documentable_type)
#  idx_captain_responses_account_visibility                (account_id,visibility)
#  index_captain_assistant_responses_on_account_id         (account_id)
#  index_captain_assistant_responses_on_assistant_id       (assistant_id)
#  index_captain_assistant_responses_on_document_chunk_id  (document_chunk_id)
#  index_captain_assistant_responses_on_status             (status)
#  vector_idx_knowledge_entries_embedding                  (embedding) USING ivfflat
#
# Foreign Keys
#
#  fk_rails_...  (document_chunk_id => captain_document_chunks.id) ON DELETE => nullify
#
class Captain::AssistantResponse < ApplicationRecord
  self.table_name = 'captain_assistant_responses'

  belongs_to :assistant, class_name: 'Captain::Assistant', optional: true
  belongs_to :account
  belongs_to :documentable, polymorphic: true, optional: true
  belongs_to :document_chunk, class_name: 'Captain::DocumentChunk', optional: true
  include Concerns::CaptainKnowledgeAccess
  has_neighbors :embedding, normalize: true

  validates :question, presence: true
  validates :answer, presence: true
  validate :assistant_belongs_to_account
  validate :knowledge_sources_belong_to_account

  before_validation :ensure_account
  before_validation :ensure_status
  before_validation :mark_as_edited, on: :update
  after_commit :update_response_embedding

  scope :ordered, -> { order(created_at: :desc) }
  scope :by_account, ->(account_id) { where(account_id: account_id) }
  scope :by_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }
  scope :with_document, ->(document_id) { where(document_id: document_id) }
  # assistant_id nil is workspace-owned knowledge. These rows can be general or
  # workspace-personal, but they are not assistant-private records.
  scope :workspace_owned, -> { where(assistant_id: nil) }
  scope :visible_to_assistant, lambda { |assistant_id|
    documents = Captain::Document.visible_to_assistant(assistant_id).select(:id)
    source_document_access = <<~SQL.squish
      captain_assistant_responses.documentable_type = 'Captain::Document'
      AND captain_assistant_responses.documentable_id IN (#{documents.to_sql})
    SQL
    # Generated FAQs inherit their source permissions. An explicit FAQ selection
    # may narrow that access, and can never expose a private source document.
    own_access = local_knowledge_access_sql(assistant_id)
    relation = where(<<~SQL.squish)
      (#{source_document_access} AND (
        (captain_assistant_responses.restricted_to_assistants = FALSE AND
          (captain_assistant_responses.visibility = #{visibilities[:general]} OR
           captain_assistant_responses.assistant_id IS NULL OR
           captain_assistant_responses.assistant_id =
             (SELECT assistant_id FROM captain_documents WHERE id = captain_assistant_responses.documentable_id))) OR
        (#{own_access})
      )) OR
      (COALESCE(captain_assistant_responses.documentable_type, '') <> 'Captain::Document' AND (#{own_access}))
    SQL
    relation = relation.where(account_id: Captain::Assistant.where(id: assistant_id).select(:account_id)) if assistant_id.present?
    chunks = Captain::DocumentChunk.where(document_id: documents).select(:id)
    relation.where('captain_assistant_responses.document_chunk_id IS NULL OR captain_assistant_responses.document_chunk_id IN (?)', chunks)
  }
  scope :generally_visible, lambda {
    documents = Captain::Document.generally_visible.select(:id)
    where(visibility: visibilities[:general])
      .where("COALESCE(documentable_type, '') <> 'Captain::Document' OR documentable_id IN (?)", documents)
      .where('document_chunk_id IS NULL OR document_chunk_id IN (?)', Captain::DocumentChunk.where(document_id: documents).select(:id))
  }

  enum status: { pending: 0, approved: 1 }
  enum visibility: { general: 0, personal: 1 }, _prefix: :visibility

  def self.search(query, account_id:, assistant_id: nil, limit: 5)
    return none if account_id.blank?

    embedding = Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(
      query,
      input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE
    )
    nearest_neighbors(:embedding, embedding, distance: 'cosine')
      .approved
      .visible_to_assistant(assistant_id)
      .where(account_id: account_id)
      .where.not(embedding: nil)
      .limit(limit)
  end

  def self.lexical_search(query, account_id:, assistant_id: nil, limit: 5)
    tokens = lexical_tokens(query)
    return none if account_id.blank? || tokens.blank?

    bind_values = lexical_bind_values(tokens)

    approved
      .visible_to_assistant(assistant_id)
      .where(account_id: account_id)
      .where(lexical_conditions(tokens), bind_values)
      .order(Arel.sql(lexical_ranking(query, tokens, bind_values)))
      .limit(limit)
  end

  def self.exact_search(query, account_id:, assistant_id: nil, limit: 5)
    normalized_query = query.to_s.squish.downcase
    return none if account_id.blank? || normalized_query.blank?

    approved
      .visible_to_assistant(assistant_id)
      .where(account_id: account_id)
      .where('LOWER(BTRIM(question)) = ?', normalized_query)
      .order(created_at: :desc)
      .limit(limit)
  end

  def self.lexical_tokens(query)
    query.to_s.downcase.scan(/[\p{Alnum}]+/).select { |token| token.length >= 3 }.uniq.first(5)
  end

  def self.lexical_bind_values(tokens)
    tokens.each_with_index.to_h do |token, index|
      ["term_#{index}".to_sym, "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"]
    end
  end

  def self.lexical_conditions(tokens)
    tokens.each_index.map do |index|
      "LOWER(question) LIKE :term_#{index} OR LOWER(answer) LIKE :term_#{index}"
    end.join(' OR ')
  end

  def self.lexical_ranking(query, tokens, bind_values)
    question_relevance = lexical_relevance(tokens) { |index| "LOWER(question) LIKE :term_#{index}" }
    distinct_relevance = lexical_relevance(tokens) do |index|
      "LOWER(question) LIKE :term_#{index} OR LOWER(answer) LIKE :term_#{index}"
    end
    answer_relevance = lexical_relevance(tokens) { |index| "LOWER(answer) LIKE :term_#{index}" }
    sanitize_sql_array(
      [
        <<~SQL.squish,
          CASE WHEN LOWER(BTRIM(question)) = :exact_query THEN 0 ELSE 1 END,
          (#{question_relevance}) DESC,
          (#{distinct_relevance}) DESC,
          LENGTH(BTRIM(question)) ASC,
          (#{answer_relevance}) DESC,
          created_at DESC
        SQL
        bind_values.merge(exact_query: query.to_s.squish.downcase)
      ]
    )
  end

  def self.lexical_relevance(tokens)
    tokens.each_index.map { |index| "CASE WHEN #{yield(index)} THEN 1 ELSE 0 END" }.join(' + ')
  end
  private_class_method :lexical_tokens, :lexical_bind_values, :lexical_conditions, :lexical_ranking, :lexical_relevance

  def inherited_knowledge_source
    return if restricted_to_assistants? || documentable_type != 'Captain::Document'
    return if documentable.blank? || documentable.account_id != account_id
    return unless visibility_general? || assistant_id.nil? || assistant_id == documentable.assistant_id

    documentable
  end

  private

  def ensure_status
    self.status ||= :approved
  end

  def mark_as_edited
    self.edited = true if question_changed? || answer_changed?
  end

  def ensure_account
    self.account ||= assistant&.account ||
                     documentable&.try(:account) ||
                     document_chunk&.account
  end

  def assistant_belongs_to_account
    return if assistant.blank? || account.blank? || assistant.account_id == account_id

    errors.add(:assistant, 'must belong to the same account')
  end

  def knowledge_sources_belong_to_account
    if documentable_type == 'Captain::Document' && documentable.present? && documentable.account_id != account_id
      errors.add(:documentable, 'must belong to the same account')
    end
    return if document_chunk.blank? || document_chunk.account_id == account_id

    errors.add(:document_chunk, 'must belong to the same account')
  end

  def update_response_embedding
    return unless saved_change_to_question? || saved_change_to_answer? || embedding.nil?

    Captain::Llm::UpdateEmbeddingJob.perform_later(self, "#{question}: #{answer}")
  end
end
