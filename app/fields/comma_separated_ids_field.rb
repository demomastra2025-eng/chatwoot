require 'administrate/field/string'

class CommaSeparatedIdsField < Administrate::Field::String
  # A string field is searchable by default, which puts this virtual attribute
  # (it has no column) into the SQL of the index search and fails every text
  # search of the list.
  def self.searchable?
    false
  end

  def normalized_ids
    Array(data.is_a?(String) ? data.split(/[,\s]+/) : data)
      .filter_map do |candidate|
        Integer(candidate.to_s.strip, 10)
      rescue ArgumentError, TypeError
        nil
      end
      .select(&:positive?)
      .uniq
      .sort
  end

  def to_s
    normalized_ids.join(', ')
  end
end
