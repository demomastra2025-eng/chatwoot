# frozen_string_literal: true

# A unified diff of two texts, line by line (the format of `diff -u`), without a gem: the production bundle has no diff library.
# The onelink:captain:apply_prompts_v2 rake prints the change of every prompt with it before anything is written.
#
#   Captain::TextDiff.unified("a\nb\nc", "a\nB\nc", from: 'stored', to: 'file')
#   # => "--- stored\n+++ file\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
#
# The same texts give an empty string. A final line end is not a difference.
class Captain::TextDiff
  CONTEXT_LINES = 3
  MARKS = { same: ' ', removed: '-', added: '+' }.freeze
  # Above this many cells the longest common part is not searched: the whole old text is shown removed and the new one added.
  MAX_TABLE_CELLS = 4_000_000

  def self.unified(old_text, new_text, from:, to:)
    new(old_text, new_text).unified(from: from, to: to)
  end

  def initialize(old_text, new_text)
    @old_lines = old_text.to_s.lines.map(&:chomp)
    @new_lines = new_text.to_s.lines.map(&:chomp)
  end

  def unified(from:, to:)
    return '' if @old_lines == @new_lines

    ["--- #{from}", "+++ #{to}", *hunks.flat_map { |hunk| hunk_lines(hunk) }].join("\n") << "\n"
  end

  private

  # [kind, old_index, new_index, line] for every line of both texts, kind :same, :removed or :added. The indexes are the numbers
  # of old and new lines before this one.
  def operations
    @operations ||= begin
      table = common_lengths
      operations = []
      old_index = 0
      new_index = 0
      while old_index < @old_lines.size || new_index < @new_lines.size
        kind = next_kind(table, old_index, new_index)
        operations << [kind, old_index, new_index, kind == :added ? @new_lines[new_index] : @old_lines[old_index]]
        old_index += 1 unless kind == :added
        new_index += 1 unless kind == :removed
      end
      operations
    end
  end

  def next_kind(table, old_index, new_index)
    return :added if old_index >= @old_lines.size
    return :removed if new_index >= @new_lines.size
    return :same if @old_lines[old_index] == @new_lines[new_index]
    return :removed if table.nil?

    table[old_index + 1][new_index] >= table[old_index][new_index + 1] ? :removed : :added
  end

  # table[i][j]: the length of the longest common sequence of old lines i.. and new lines j..; nil when the texts are too long
  def common_lengths
    rows = @old_lines.size
    columns = @new_lines.size
    return if (rows + 1) * (columns + 1) > MAX_TABLE_CELLS

    table = Array.new(rows + 1) { Array.new(columns + 1, 0) }
    (rows - 1).downto(0) { |old_index| fill_row(table, old_index) }
    table
  end

  def fill_row(table, old_index)
    row = table[old_index]
    below = table[old_index + 1]
    old_line = @old_lines[old_index]
    (@new_lines.size - 1).downto(0) do |new_index|
      row[new_index] = old_line == @new_lines[new_index] ? below[new_index + 1] + 1 : [below[new_index], row[new_index + 1]].max
    end
  end

  # Ranges of operation indexes: each change with up to CONTEXT_LINES unchanged lines around it, close changes in one range
  def hunks
    changed = operations.each_index.reject { |index| operations[index].first == :same }
    changed.each_with_object([]) do |index, ranges|
      first = [index - CONTEXT_LINES, 0].max
      last = [index + CONTEXT_LINES, operations.size - 1].min
      if ranges.any? && first <= ranges.last.last + 1
        ranges[-1] = (ranges.last.first..last)
      else
        ranges << (first..last)
      end
    end
  end

  def hunk_lines(range)
    slice = operations[range]
    old_count = slice.count { |kind, *| kind != :added }
    new_count = slice.count { |kind, *| kind != :removed }
    header = "@@ -#{position(slice.first[1], old_count)} +#{position(slice.first[2], new_count)} @@"
    [header, *slice.map { |kind, _old, _new, line| "#{MARKS.fetch(kind)}#{line}" }]
  end

  # "start,count" with 1-based lines; an empty side starts at the line before it, and a count of 1 is left out (as diff -u does)
  def position(lines_before, count)
    return "#{lines_before},0" if count.zero?

    count == 1 ? (lines_before + 1).to_s : "#{lines_before + 1},#{count}"
  end
end
