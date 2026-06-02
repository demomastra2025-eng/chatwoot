# == Schema Information
#
# Table name: captain_knowledge_answer_cache_entries
#
#  id                 :bigint           not null, primary key
#  embedding          :vector(1536)
#  expires_at         :datetime
#  hit_count          :integer          default(0), not null
#  last_hit_at        :datetime
#  payload            :jsonb            not null
#  query              :text             not null
#  query_sha256       :string           not null
#  source_fingerprint :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  assistant_id       :bigint
#
# Indexes
#
#  idx_captain_answer_cache_exact                                (account_id,assistant_id,query_sha256,source_fingerprint) UNIQUE
#  idx_captain_answer_cache_expires_at                           (expires_at)
#  index_captain_knowledge_answer_cache_entries_on_account_id    (account_id)
#  index_captain_knowledge_answer_cache_entries_on_assistant_id  (assistant_id)
#  vector_idx_captain_answer_cache_embedding                     (embedding) USING ivfflat
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (assistant_id => captain_assistants.id)
#
class Captain::KnowledgeAnswerCacheEntry < ApplicationRecord
  self.table_name = 'captain_knowledge_answer_cache_entries'

  DEFAULT_DISTANCE_THRESHOLD = 0.15

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant', optional: true
  has_neighbors :embedding, normalize: true

  validates :query, presence: true
  validates :query_sha256, presence: true
  validates :source_fingerprint, presence: true
  validates :payload, presence: true
  validate :assistant_belongs_to_account

  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :for_scope, lambda { |account:, assistant:, source_fingerprint:|
    where(account_id: account.id, assistant_id: assistant&.id, source_fingerprint: source_fingerprint)
  }

  def self.semantic_match(embedding:, account:, assistant:, source_fingerprint:, distance_threshold: DEFAULT_DISTANCE_THRESHOLD)
    return if embedding.blank?

    for_scope(account: account, assistant: assistant, source_fingerprint: source_fingerprint)
      .active
      .where.not(embedding: nil)
      .nearest_neighbors(:embedding, embedding, distance: 'cosine')
      .limit(1)
      .detect { |entry| entry.neighbor_distance.to_f <= distance_threshold }
  end

  private

  def assistant_belongs_to_account
    return if assistant.blank? || account.blank? || assistant.account_id == account.id

    errors.add(:assistant, 'must belong to the same account')
  end
end
