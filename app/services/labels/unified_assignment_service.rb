class Labels::UnifiedAssignmentService
  def self.union_for(contact:, conversations:)
    labels = []
    labels.concat(contact.label_list) if contact.present?
    Array(conversations).compact.each { |conversation| labels.concat(conversation.label_list) }
    normalize(labels)
  end

  def self.normalize(labels)
    Array(labels).flatten.compact.map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def initialize(contact:, conversations:, labels:)
    @contact = contact
    @conversations = Array(conversations).compact
    @labels = self.class.normalize(labels)
  end

  def perform
    ActiveRecord::Base.transaction do
      contact.update_labels(labels) if contact.present?
      conversations.each { |conversation| conversation.update_labels(labels) }
    end

    labels
  end

  private

  attr_reader :contact, :conversations, :labels
end
