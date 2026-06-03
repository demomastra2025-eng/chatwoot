# == Schema Information
#
# Table name: captain_document_chunks
#
#  id                   :bigint           not null, primary key
#  chunk_index          :integer          not null
#  content              :text             not null
#  content_sha256       :string           not null
#  embedding            :vector(1536)
#  embedding_error      :text
#  embedding_status     :integer          default("pending"), not null
#  embedding_updated_at :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  assistant_id         :bigint
#  document_id          :bigint           not null
#
# Indexes
#
#  index_captain_document_chunks_on_account_id                   (account_id)
#  index_captain_document_chunks_on_assistant_id                 (assistant_id)
#  index_captain_document_chunks_on_content_sha256               (content_sha256)
#  index_captain_document_chunks_on_document_id                  (document_id)
#  index_captain_document_chunks_on_document_id_and_chunk_index  (document_id,chunk_index) UNIQUE
#  index_captain_document_chunks_on_embedding_status             (embedding_status)
#  vector_idx_captain_document_chunks_embedding                  (embedding) USING ivfflat
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (assistant_id => captain_assistants.id)
#  fk_rails_...  (document_id => captain_documents.id)
#
class Captain::DocumentChunk < ApplicationRecord
  self.table_name = 'captain_document_chunks'

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant', optional: true
  belongs_to :document, class_name: 'Captain::Document'
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :nullify
  has_neighbors :embedding, normalize: true

  validates :chunk_index, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :content, presence: true
  validates :content_sha256, presence: true
  validates :chunk_index, uniqueness: { scope: :document_id }

  enum embedding_status: { pending: 0, indexed: 1, failed: 2, stale: 3 }, _prefix: :embedding

  before_validation :ensure_associations
  before_validation :ensure_content_sha256
  before_validation :ensure_embedding_status
  before_save :mark_embedding_stale, if: :will_save_change_to_content?
  after_commit :update_chunk_embedding

  scope :needs_embedding_reindex, lambda {
    where(embedding_status: [embedding_statuses[:pending], embedding_statuses[:failed], embedding_statuses[:stale]])
      .or(where(embedding: nil))
  }
  scope :visible_to_assistant, lambda { |assistant_id|
    relation = joins(:document)
    if assistant_id.blank?
      relation.where(captain_documents: { assistant_id: nil })
    else
      relation.where(
        <<~SQL.squish,
          captain_documents.assistant_id IS NULL OR
          captain_documents.visibility = :general_visibility OR
          captain_documents.assistant_id = :assistant_id
        SQL
        general_visibility: Captain::Document.visibilities[:general],
        assistant_id: assistant_id
      )
    end
  }

  def self.search(query, account_id: nil)
    return none if account_id.blank?

    embedding = Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(
      query,
      input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE
    )
    nearest_neighbors(:embedding, embedding, distance: 'cosine')
      .where(account_id: account_id)
      .where(embedding_status: embedding_statuses[:indexed])
      .where.not(embedding: nil)
      .limit(5)
  end

  private

  def ensure_associations
    self.account ||= document&.account
    self.assistant ||= document&.assistant
  end

  def ensure_content_sha256
    self.content_sha256 = Digest::SHA256.hexdigest(content.to_s) if content.present?
  end

  def ensure_embedding_status
    self.embedding_status ||= :pending
  end

  def mark_embedding_stale
    self.embedding_status = :stale if persisted?
  end

  def update_chunk_embedding
    return if embedding_failed? && !saved_change_to_content?
    return unless saved_change_to_content? || embedding.nil? || embedding_pending? || embedding_stale?

    Captain::Llm::UpdateEmbeddingJob.perform_later(self, content)
  end
end
