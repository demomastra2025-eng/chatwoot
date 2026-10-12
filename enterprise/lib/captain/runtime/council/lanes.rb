# frozen_string_literal: true

# Which parts of a council run one after another and which run side by side. A pure function over plain data.
#
# Every part whose owner can WRITE (it has a mutating tool) belongs to ONE lane that runs in plan order on the thread of the
# job, even for different patients: the provider allows one unfinished new-patient command per chat contact, a booking can
# create or attach the same CRM deal, and all writes then stay on the thread that carries the user, the delivery policy and
# the durable session. Every read-only part is a lane of its own that can run on a thread, with these exceptions, which are
# joined into one lane (and into the writer lane when either side is a writer), always in plan order:
#   * a part that depends on another part (relation depends_on or conditional) follows its prerequisite;
#   * parts that name the same object (type and id) share a lane.
# The merge is transitive.
class Captain::Runtime::Council::Lanes
  Plan = Struct.new(:id, :writer, :prerequisite_id, :object_refs, keyword_init: true)

  # plans: in the order of the request. Returns { writer: [plan, ...], readers: [[plan, ...], ...] }; every lane is in plan order.
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
    writer_groups, reader_groups = groups.partition { |group| group.any? { |index| @plans[index].writer } }
    {
      writer: writer_groups.flatten.sort.map { |index| @plans[index] },
      readers: reader_groups.sort_by(&:min).map { |group| group.sort.map { |index| @plans[index] } }
    }
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
