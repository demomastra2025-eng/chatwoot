class Crm::BoardPositioner
  class << self
    def normalize!(scope:)
      new(scope: scope).normalize!
    end

    def place!(scope:, record:, target_position:)
      new(scope: scope, record: record, target_position: target_position).place!
    end
  end

  def initialize(scope:, record: nil, target_position: nil)
    @scope = scope
    @record = record
    @target_position = target_position
  end

  def normalize!
    persist_positions!(ordered_scope.to_a)
  end

  def place!
    records = ordered_scope.to_a.reject { |item| item.id == record.id }
    records.insert(normalized_index(records.length), record)
    persist_positions!(records)
  end

  private

  attr_reader :record, :scope, :target_position

  def normalized_index(length)
    requested_position = target_position.to_i
    return length if requested_position <= 0

    [[requested_position - 1, 0].max, length].min
  end

  def ordered_scope
    scope.lock.reorder(position: :asc, id: :asc)
  end

  def persist_positions!(records)
    records.each_with_index do |item, index|
      next_position = index + 1
      next if item.position == next_position

      item.update_columns(position: next_position)
      item.position = next_position
    end
  end
end
