# Counts all / mine / unassigned rows of a conversation or communication thread relation with one
# FILTER aggregate query instead of three separate COUNT queries.
#
# Relations that the aggregate cannot be applied to directly (pagination, grouping, eager loading
# for a joined search) fall back to the three plain counts, so the numbers never differ.
class Conversations::AssigneeCountsAggregator
  def initialize(relation, user_id:)
    @relation = relation
    @user_id = user_id.to_i
  end

  def perform
    return fallback_counts unless aggregatable?

    all_count, mine_count, unassigned_count = countable_relation.pick(*aggregate_columns)
    { all_count: all_count.to_i, mine_count: mine_count.to_i, unassigned_count: unassigned_count.to_i }
  end

  private

  attr_reader :relation, :user_id

  def aggregatable?
    relation.limit_value.nil? &&
      relation.offset_value.nil? &&
      relation.group_values.empty? &&
      !relation.eager_loading?
  end

  # Plucking from a relation with includes would join the preloaded tables and multiply the rows.
  def countable_relation
    relation.except(:order, :includes, :preload)
  end

  def aggregate_columns
    [
      counted_rows,
      counted_rows.filter(table[:assignee_id].eq(user_id)),
      counted_rows.filter(table[:assignee_id].eq(nil))
    ]
  end

  def fallback_counts
    {
      all_count: relation.count,
      mine_count: relation.where(assignee_id: user_id).count,
      unassigned_count: relation.where(assignee_id: nil).count
    }
  end

  # A relation that is already DISTINCT (joined labels) is counted per record, like relation.distinct.count does.
  def counted_rows
    return Arel::Nodes::Count.new([Arel.star]) unless relation.distinct_value

    Arel::Nodes::Count.new([table[relation.klass.primary_key]], true)
  end

  def table
    relation.klass.arel_table
  end
end
