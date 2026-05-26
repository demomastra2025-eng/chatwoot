# == Schema Information
#
# Table name: captain_document_chunks
#
#  id             :bigint           not null, primary key
#  chunk_index    :integer          not null
#  content        :text             not null
#  content_sha256 :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  assistant_id   :bigint           not null
#  document_id    :bigint           not null
#
# Indexes
#
#  index_captain_document_chunks_on_account_id               (account_id)
#  index_captain_document_chunks_on_assistant_id             (assistant_id)
#  index_captain_document_chunks_on_content_sha256           (content_sha256)
#  index_captain_document_chunks_on_document_id              (document_id)
#  index_captain_document_chunks_on_document_id_and_chunk_index  (document_id,chunk_index) UNIQUE
#
class Captain::DocumentChunk < ApplicationRecord
  self.table_name = 'captain_document_chunks'

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :document, class_name: 'Captain::Document'
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :nullify

  validates :chunk_index, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :content, presence: true
  validates :content_sha256, presence: true
  validates :chunk_index, uniqueness: { scope: :document_id }

  before_validation :ensure_associations
  before_validation :ensure_content_sha256

  private

  def ensure_associations
    self.account ||= document&.account
    self.assistant ||= document&.assistant
  end

  def ensure_content_sha256
    self.content_sha256 = Digest::SHA256.hexdigest(content.to_s) if content.present?
  end
end
