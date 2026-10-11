# frozen_string_literal: true

# assistant_id remains a legacy owner. Grants add access without copying the
# material; restricted_to_assistants distinguishes an explicit selection from
# older workspace-owned personal knowledge.
module Concerns::CaptainKnowledgeAccess
  extend ActiveSupport::Concern

  included do
    has_many :knowledge_grants, class_name: 'Captain::KnowledgeGrant', as: :knowledge_record, dependent: :destroy

    before_validation :normalize_knowledge_access
    validate :validate_allowed_assistants
    after_save :persist_knowledge_grants
  end

  class_methods do
    def local_knowledge_access_sql(assistant_id, table: table_name)
      return "#{table}.assistant_id IS NULL AND #{table}.restricted_to_assistants = FALSE" if assistant_id.blank?

      sanitize_sql_array([
        <<~SQL.squish,
          EXISTS (
            SELECT 1 FROM captain_assistants knowledge_actor
            WHERE knowledge_actor.id = :assistant_id AND knowledge_actor.account_id = #{table}.account_id
          ) AND (
            #{table}.visibility = :general_visibility OR
            (#{table}.assistant_id IS NULL AND #{table}.restricted_to_assistants = FALSE) OR
            #{table}.assistant_id = :assistant_id OR
            EXISTS (
              SELECT 1 FROM captain_knowledge_grants knowledge_grant
              WHERE knowledge_grant.knowledge_record_type = :record_type
                AND knowledge_grant.knowledge_record_id = #{table}.id
                AND knowledge_grant.account_id = #{table}.account_id
                AND knowledge_grant.assistant_id = :assistant_id
            )
          )
        SQL
        assistant_id: assistant_id, general_visibility: visibilities[:general], record_type: name
      ])
    end
  end

  def allowed_assistant_ids
    if !defined?(@allowed_assistant_ids) && respond_to?(:inherited_knowledge_source) && (source = inherited_knowledge_source)
      return source.allowed_assistant_ids
    end
    return [] if visibility_general?

    ids = if defined?(@allowed_assistant_ids)
            @allowed_assistant_ids
          else
            knowledge_grants.map(&:assistant_id)
          end
    (Array(ids) + [assistant_id]).compact.uniq.sort
  end

  def allowed_assistant_ids=(ids)
    @allowed_assistant_ids = Array(ids).reject(&:blank?).map(&:to_s).uniq
    @allowed_assistant_ids_invalid = @allowed_assistant_ids.any? { |id| !id.match?(/\A[1-9]\d*\z/) }
    @allowed_assistant_ids = @allowed_assistant_ids.map(&:to_i)
  end

  def agent_restricted_knowledge?
    visibility_personal? && (restricted_to_assistants? || assistant_id.present?)
  end

  private

  def normalize_knowledge_access
    if visibility_general?
      self.restricted_to_assistants = false
    elsif defined?(@allowed_assistant_ids)
      self.restricted_to_assistants = true
    end
  end

  def validate_allowed_assistants
    return unless defined?(@allowed_assistant_ids)

    if @allowed_assistant_ids_invalid || account_id.blank? ||
       Captain::Assistant.where(account_id: account_id, id: @allowed_assistant_ids).count != @allowed_assistant_ids.length
      errors.add(:allowed_assistant_ids, 'must contain agents from the same account')
    end
    return if visibility_general? || allowed_assistant_ids.any?

    errors.add(:allowed_assistant_ids, 'must include at least one agent for personal knowledge')
  end

  def persist_knowledge_grants
    return unless visibility_general? || defined?(@allowed_assistant_ids)

    ids = visibility_general? ? [] : (@allowed_assistant_ids - [assistant_id])
    knowledge_grants.where.not(assistant_id: ids).destroy_all
    ids.each do |id|
      knowledge_grants.find_or_create_by!(assistant_id: id) { |grant| grant.account_id = account_id }
    end
    remove_instance_variable(:@allowed_assistant_ids) if defined?(@allowed_assistant_ids)
    knowledge_grants.reset
  end
end
