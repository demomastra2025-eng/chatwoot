# frozen_string_literal: true

# The organizations as the options of a select in the super admin (the account form, the «Организация» block of the card,
# the filter of the account list): [["Алатау · БИН 980140000124", 7], ...], by name. Names may repeat, so every option
# also says which one it is: the БИН, or the id when the organization has none.
class SuperAdmin::OrganizationOptions
  # One query for the whole list; only the three columns the labels need are read
  def self.for_select
    Organization.order(Arel.sql('LOWER(name)'), :id).pluck(:name, :bin, :id).map do |name, bin, id|
      [label(name, bin, id), id]
    end
  end

  def self.label(name, bin, id)
    suffix = bin.present? ? "#{Organization.human_attribute_name(:bin)} #{bin}" : "##{id}"
    "#{name} · #{suffix}"
  end
end
