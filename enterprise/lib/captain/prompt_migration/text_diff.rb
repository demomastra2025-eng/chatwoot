# frozen_string_literal: true

# A unified line diff of two texts (no gem: the prompts are short), for the dry run of the prompt migration.
module Captain::PromptMigration::TextDiff
  CONTEXT = 3

  module_function

  # Returns the diff as a String ('' when the texts are equal), with --- / +++ headers named by label.
  def unified(before, after, label:)
    old_lines = before.to_s.split("\n", -1)
    new_lines = after.to_s.split("\n", -1)
    return '' if old_lines == new_lines

    ops = operations(old_lines, new_lines)
    (["--- #{label} (current)", "+++ #{label} (proposed)"] + hunks(ops)).join("\n")
  end

  # [[:same|:del|:add, line, old_index, new_index]] from the longest common subsequence of the lines.
  def operations(old_lines, new_lines)
    table = lcs_table(old_lines, new_lines)
    ops = []
    i = j = 0
    while i < old_lines.size || j < new_lines.size
      step = step_at(old_lines, new_lines, table, i, j)
      ops << [step, step == :add ? new_lines[j] : old_lines[i], i, j]
      i += 1 unless step == :add
      j += 1 unless step == :del
    end
    ops
  end

  def step_at(old_lines, new_lines, table, row, column)
    return :add if row >= old_lines.size
    return :del if column >= new_lines.size
    return :same if old_lines[row] == new_lines[column]

    table[row + 1][column] >= table[row][column + 1] ? :del : :add
  end

  def lcs_table(old_lines, new_lines)
    table = Array.new(old_lines.size + 1) { Array.new(new_lines.size + 1, 0) }
    (old_lines.size - 1).downto(0) do |i|
      (new_lines.size - 1).downto(0) { |j| table[i][j] = lcs_cell(table, i, j, old_lines[i] == new_lines[j]) }
    end
    table
  end

  def lcs_cell(table, row, column, equal)
    equal ? table[row + 1][column + 1] + 1 : [table[row + 1][column], table[row][column + 1]].max
  end

  # The changed operations with CONTEXT unchanged lines around them, one @@ header per group.
  def hunks(ops)
    changed = ops.each_index.reject { |index| ops[index][0] == :same }
    changed.slice_when { |a, b| b - a > (CONTEXT * 2) + 1 }.flat_map { |group| hunk(ops, group) }
  end

  def hunk(ops, group)
    slice = ops[[group.first - CONTEXT, 0].max..[group.last + CONTEXT, ops.size - 1].min]
    ["@@ -#{slice.first[2] + 1} +#{slice.first[3] + 1} @@", *slice.map { |op| line_for(op) }]
  end

  def line_for(operation)
    prefix = { same: ' ', del: '-', add: '+' }.fetch(operation[0])
    "#{prefix}#{operation[1]}"
  end
end
