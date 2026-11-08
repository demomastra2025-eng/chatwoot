class Api::V1::Accounts::Conversations::LabelsController < Api::V1::Accounts::Conversations::BaseController
  include LabelConcern

  private

  # A whole list from an older client was built from the labels of this conversation.
  def visible_labels
    @conversation.label_list
  end

  def change_labels(add:, remove:)
    record_human_label_decisions!(add: add, remove: remove)
    Labels::UnifiedAssignmentService.new(
      contact: @conversation.contact,
      conversation: @conversation,
      add: add,
      remove: remove
    ).perform
    @conversation.reload
    @conversation.contact.reload
  end

  def record_human_label_decisions!(add:, remove:)
    added_norm = Labels::UnifiedAssignmentService.normalize(add).map(&:downcase)
    removed_norm = Labels::UnifiedAssignmentService.normalize(remove).map(&:downcase)
    return if added_norm.empty? && removed_norm.empty?

    attrs = @conversation.additional_attributes.to_h.deep_dup
    existing_removed = Array(attrs['human_removed_labels']).map { |l| l.to_s.strip.downcase }
    updated_removed = ((existing_removed - added_norm) + removed_norm).uniq
    attrs['human_removed_labels'] = updated_removed

    if attrs['ai_suggested_labels'].is_a?(Array)
      touched = (added_norm + removed_norm).to_set
      attrs['ai_suggested_labels'] = attrs['ai_suggested_labels'].reject { |l| touched.include?(l.to_s.strip.downcase) }
    end

    @conversation.update_columns(additional_attributes: attrs)
  end

  def current_label_list
    Labels::UnifiedAssignmentService.union_for(contact: @conversation.contact, conversations: [@conversation])
  end

  def permitted_params
    params.permit(:conversation_id, labels: [], add: [], remove: [])
  end
end
