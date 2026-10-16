# frozen_string_literal: true

# The order of the organization list. Names may repeat and are typed in any case, so a list sorted by name is sorted by
# the lower case name (the index of organizations) and then by id: a page never repeats or loses a row of a repeated name.
# Any other column is sorted as Administrate does it, with the id as the tie-break.
class SuperAdmin::OrganizationListOrder < Administrate::Order
  def apply(relation)
    return super.order(:id) unless ordered_by?(:name)

    relation.reorder(Arel::Nodes::NamedFunction.new('LOWER', [relation.arel_table[:name]]).public_send(direction), :id)
  end
end
