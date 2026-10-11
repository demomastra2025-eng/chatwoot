# frozen_string_literal: true

class Captain::KnowledgeGrant < ApplicationRecord
  self.table_name = 'captain_knowledge_grants'
  KNOWLEDGE_RECORD_TYPES = %w[Captain::Document Captain::AssistantResponse].freeze

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :knowledge_record, polymorphic: true

  validates :knowledge_record_type, inclusion: { in: KNOWLEDGE_RECORD_TYPES }
  validates :assistant_id, uniqueness: { scope: [:knowledge_record_type, :knowledge_record_id] }
  validate :same_account
  after_create :restrict_selected_workspace_material

  # A direct grant removal must also invalidate retrieval cached before revocation.
  after_commit :invalidate_knowledge_cache

  private

  def same_account
    errors.add(:assistant, 'must belong to the same account') if assistant.present? && assistant.account_id != account_id
    return unless KNOWLEDGE_RECORD_TYPES.include?(knowledge_record_type)
    return if knowledge_record.blank? || knowledge_record.account_id == account_id

    errors.add(:knowledge_record, 'must belong to the same account')
  end

  def invalidate_knowledge_cache
    Captain::KnowledgeAnswerCacheEntry.where(account_id: account_id).delete_all
  end

  def restrict_selected_workspace_material
    return unless knowledge_record.visibility_personal? && knowledge_record.assistant_id.nil?
    return if knowledge_record.restricted_to_assistants?

    knowledge_record.update_columns(restricted_to_assistants: true, updated_at: Time.current)
  end
end
