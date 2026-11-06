# Personal MTProto and Bot API use the same escaped Telegram HTML contract.
# The personal gateway converts it to native entities before sending.
class Messages::MarkdownRenderers::TelegramPersonalRenderer < Messages::MarkdownRenderers::TelegramRenderer
  def initialize(source: '')
    super()
    @source_lines = source.lines
  end

  def document(node)
    node.each_with_index do |child, index|
      if index.positive?
        cr
        preceding_lines = @source_lines.take(child.sourcepos[:start_line] - 1)
        blank_lines = preceding_lines.reverse.take_while { |line| line.strip.empty? }.length
        out("\n" * blank_lines)
      end
      out(child)
    end
  end
end
