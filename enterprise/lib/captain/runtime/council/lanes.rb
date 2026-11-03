# frozen_string_literal: true

# Which parts of a council run one after another and which run side by side. A pure function over plain data.
#
# Independent parts have separate lanes, including owners that have action tools: actual writes share the council's guard
# in ToolWrapper, without blocking another part's model or reads. These exceptions share a lane, in plan order:
#   * a part that depends on another part (relation depends_on or conditional) follows its prerequisite;
#   * parts that name the same business object (type and id) share a lane. The common patient/contact is not such a dependency.
# The merge is transitive.
class Captain::Runtime::Council::Lanes
  IDENTITY_REFS = %w[patient contact].freeze
  Plan = Struct.new(:id, :writer, :prerequisite_id, :object_refs, keyword_init: true)

  # plans: in the order of the request. Returns [[plan, ...], ...]; every lane is in plan order.
  def self.build(plans)
    new(plans).build
  end

  def initialize(plans)
    @plans = plans.to_a
    @parent = @plans.each_index.to_a
  end

  def build
    join_prerequisites
    join_shared_objects
    groups = @plans.each_index.group_by { |index| find(index) }.values
    groups.sort_by(&:min).map { |group| group.sort.map { |index| @plans[index] } }
  end

  private

  def join_prerequisites
    positions = @plans.each_with_index.to_h { |plan, index| [plan.id, index] }
    @plans.each_with_index do |plan, index|
      prerequisite = positions[plan.prerequisite_id]
      union(prerequisite, index) if prerequisite
    end
  end

  def join_shared_objects
    owners = {}
    @plans.each_with_index do |plan, index|
      Array(plan.object_refs).each do |ref|
        ref = ref.to_h.stringify_keys
        next if IDENTITY_REFS.include?(ref['type'].to_s)

        key = [ref['type'].to_s, ref['id'].to_s]
        union(owners[key], index) if owners.key?(key)
        owners[key] ||= index
      end
    end
  end

  def find(index)
    index = @parent[index] until @parent[index] == index
    index
  end

  def union(first, second)
    @parent[find(second)] = find(first)
  end
end
