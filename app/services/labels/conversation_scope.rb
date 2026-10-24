# frozen_string_literal: true

# Labels belong to a person in OneLink. Labels::UnifiedAssignmentService writes a label to the contact and to every
# conversation of the communication thread, and the thread shows the union of both (Labels::UnifiedAssignmentService.union_for).
# The label views must read the same union: a person whose contact carries the label but whose conversations do not
# (a conversation created after the label was set, a label set on the contact card) must not drop out of the view.
#
# A conversation matches a label when the label is on the conversation OR on its contact. The match is a plain SQL
# condition that is added to the list scope, so nothing is loaded into Ruby and every other filter of the scope (status,
# inbox, assignee, team, permissions) stays as it is:
#
#   conversations.id = ANY (ARRAY(<ids of the labeled conversations>))
#     OR conversations.contact_id = ANY (ARRAY(<ids of the labeled contacts>))
#
# Both ARRAY(SELECT ...) parts do not depend on the outer row, so Postgres runs each one once per query (an InitPlan,
# driven by the label's own taggings rows) and the OR becomes a BitmapOr over the primary key and
# index_conversations_on_contact_id. The two obvious alternatives were measured on Postgres 16 (account with 150k
# conversations in a table of 400k, 400 labeled contacts) and both are worse:
# - OR of correlated EXISTS: the planner adds the cost of one probe per conversation, the inflated cost switches JIT
#   on (about +350 ms per query) and the list takes about 400 ms where this form takes about 35 ms.
# - OR of "IN (SELECT ...)": fast for a small label, but when the labeled set no longer fits hash_mem (about 160k
#   taggings, which the any-label scope can reach because taggings is shared by all accounts) Postgres stops hashing
#   and compares every conversation with the whole subquery result: the query did not finish in 20 s.
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

      match_tags_sql(tag_ids&.map(&:to_i)&.join(', '))
    end

    # The same condition for a list or a subquery of tag ids written as SQL, for example
    # "SELECT tags.id FROM tags WHERE tags.name IN (:value_0)". Without it every label matches.
    # The result is never NULL (a conversation without a contact only matches through its own labels), so it is safe
    # under NOT.
    def match_tags_sql(tag_ids_sql = nil)
      "(conversations.id = ANY (#{labeled_ids_sql('Conversation', tag_ids_sql)}) " \
        'OR (conversations.contact_id IS NOT NULL ' \
        "AND conversations.contact_id = ANY (#{labeled_ids_sql('Contact', tag_ids_sql)})))"
    end

    # Tag names are resolved the way tagged_with does it (default parser, case-insensitive), once, to plain ids.
    def tag_ids_for(labels)
      tag_list = ActsAsTaggableOn.default_parser.new(labels).parse
      return [] if tag_list.empty?

      ActsAsTaggableOn::Tag.named_any(tag_list).pluck(:id)
    end

    private

    # Ids of the records of one type that carry a label (taggable_id IS NOT NULL keeps NULL out of the array, which
    # would turn a failed "= ANY" into NULL).
    def labeled_ids_sql(taggable_type, tag_ids_sql)
      conditions = [
        "label_taggings.taggable_type = '#{taggable_type}'",
        "label_taggings.context = 'labels'",
        'label_taggings.taggable_id IS NOT NULL',
        (tag_ids_sql && "label_taggings.tag_id IN (#{tag_ids_sql})")
      ].compact.join(' AND ')

      "ARRAY(SELECT label_taggings.taggable_id FROM taggings label_taggings WHERE #{conditions})"
    end
  end
end
