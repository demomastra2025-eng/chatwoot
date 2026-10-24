# frozen_string_literal: true

# Labels belong to a person in OneLink. Labels::UnifiedAssignmentService writes a label to the contact and to every
# conversation of the communication thread, and the thread shows the union of both (Labels::UnifiedAssignmentService.union_for).
# The label views must read the same union: a person whose contact carries the label but whose conversations do not
# (a conversation created after the label was set, a label set on the contact card) must not drop out of the view.
#
# A conversation matches a label when the label is on the conversation OR on its contact. The match is a plain SQL
# condition (EXISTS on taggings, context 'labels', once per taggable) that is added to the list scope, so nothing is
# loaded and every other filter of the scope (status, inbox, assignee, team, permissions) stays as it is. Both EXISTS
# probes use index_taggings_on_taggable_id_and_taggable_type_and_context.
#
#   Labels::ConversationScope.with_labels(scope, ['Семья'])  # replaces scope.tagged_with(labels, any: true)
#   Labels::ConversationScope.with_any_label(scope)          # conversation or contact has at least one label
class Labels::ConversationScope
  NOTHING = '1 = 0'

  class << self
    # Same label matching as tagged_with(labels, any: true) (case-insensitive tag names), plus the contact's labels.
    def with_labels(scope, labels)
      scope.where(match_sql(tag_ids_for(labels)))
    end

    def with_any_label(scope)
      scope.where(match_sql)
    end

    # SQL condition on the conversations table. Without tag ids it matches any label.
    def match_sql(tag_ids = nil)
      return NOTHING if tag_ids&.empty?

      "(#{taggings_exist_sql('Conversation', 'conversations.id', tag_ids)} " \
        "OR #{taggings_exist_sql('Contact', 'conversations.contact_id', tag_ids)})"
    end

    # Tag names are resolved the way tagged_with does it (default parser, case-insensitive), once, to plain ids.
    def tag_ids_for(labels)
      tag_list = ActsAsTaggableOn.default_parser.new(labels).parse
      return [] if tag_list.empty?

      ActsAsTaggableOn::Tag.named_any(tag_list).pluck(:id)
    end

    private

    def taggings_exist_sql(taggable_type, taggable_id_sql, tag_ids)
      tag_condition = tag_ids ? "AND label_taggings.tag_id IN (#{tag_ids.map(&:to_i).join(', ')})" : ''

      <<~SQL.squish
        EXISTS (SELECT 1 FROM taggings label_taggings
                WHERE label_taggings.taggable_id = #{taggable_id_sql}
                  AND label_taggings.taggable_type = '#{taggable_type}'
                  AND label_taggings.context = 'labels' #{tag_condition})
      SQL
    end
  end
end
