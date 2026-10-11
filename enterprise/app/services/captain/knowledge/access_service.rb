# frozen_string_literal: true

require 'digest'

class Captain::Knowledge::AccessService
  KNOWLEDGE_MODELS = [Captain::Document, Captain::AssistantResponse].freeze

  # Converted agents used to run as scenarios with their parent's knowledge.
  # Grant only the parent's restricted materials; workspace knowledge already
  # remains available through its existing visibility.
  def self.inherit_access!(from_assistant:, to_assistant:)
    unless from_assistant.account_id == to_assistant.account_id
      raise ArgumentError, 'Knowledge access can only be inherited within the same account'
    end
    return if from_assistant.id == to_assistant.id

    ActiveRecord::Base.transaction do
      KNOWLEDGE_MODELS.each do |model|
        model.where(account_id: from_assistant.account_id).visibility_personal
             .visible_to_assistant(from_assistant.id).find_each do |material|
          next unless material.agent_restricted_knowledge?

          material.knowledge_grants.find_or_create_by!(assistant: to_assistant) do |grant|
            grant.account_id = material.account_id
          end
        end
      end
    end
  end

  # Retain shared personal material under one of its remaining explicit owners.
  # Nullifying a private owner would change legacy workspace-owned semantics.
  def self.release_owner!(assistant:)
    documents = Captain::Document.where(account_id: assistant.account_id, assistant_id: assistant.id).visibility_personal
    documents.source_documents.find_each { |material| release_material!(material, assistant) }
    documents.find_each { |material| release_material!(material, assistant) }
    Captain::AssistantResponse.where(account_id: assistant.account_id, assistant_id: assistant.id)
                              .visibility_personal.find_each { |material| release_material!(material, assistant) }
  end

  def self.fingerprint(account:, assistant:)
    return unless account && assistant && assistant.account_id == account.id

    scopes = [account.captain_documents, Captain::DocumentChunk.where(account_id: account.id), account.captain_assistant_responses.approved]
    materials = scopes.map do |scope|
      [scope.count, scope.maximum(:updated_at)&.utc&.iso8601(6)]
    end
    grants = Captain::KnowledgeGrant.where(account_id: account.id).order(:id)
                                   .pluck(:id, :assistant_id, :knowledge_record_type, :knowledge_record_id, :updated_at)
    Digest::SHA256.hexdigest([account.id, assistant.id, materials, grants].to_json)
  end

  def self.release_material!(material, assistant)
    source = material_source(material)
    if source && source != material && source.assistant_id != assistant.id
      material.update!(assistant_id: source.assistant_id, visibility: source.visibility,
                       restricted_to_assistants: false)
      return
    end

    remaining_ids = material.knowledge_grants.where(account_id: assistant.account_id)
                            .where.not(assistant_id: assistant.id).order(:assistant_id).pluck(:assistant_id)
    if remaining_ids.any?
      material.update!(assistant_id: remaining_ids.first, allowed_assistant_ids: remaining_ids)
    else
      material.destroy!
    end
  end
  private_class_method :release_material!

  def self.material_source(material)
    return material.knowledge_source_document if material.is_a?(Captain::Document)

    # Explicitly selected FAQs and legacy private FAQs with a different owner
    # keep their own permissions when the source changes owners.
    material.inherited_knowledge_source&.knowledge_source_document
  end
  private_class_method :material_source
end
