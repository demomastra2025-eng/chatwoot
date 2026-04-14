require 'administrate/field/string'

class CommaSeparatedIdsField < Administrate::Field::String
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
