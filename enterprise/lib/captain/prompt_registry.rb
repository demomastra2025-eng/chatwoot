require 'liquid'

class Captain::PromptRegistry
  ROOT = Rails.root.join('enterprise/lib/captain/prompts').freeze

  class MissingPromptError < StandardError; end

  module MarkdownFilters
    def markdown_list_item(input)
      lines = normalized_markdown_lines(input)
      return '' if lines.blank?

      markdown_bullet(lines.first, lines.drop(1))
    end

    private

    def normalized_markdown_lines(input)
      trim_blank_edges(input.to_s.gsub(/\r\n?/, "\n").lines.map { |line| line.chomp.rstrip })
    end

    def trim_blank_edges(lines)
      lines.shift while lines.first&.blank?
      lines.pop while lines.last&.blank?
      lines
    end

    def markdown_bullet(first_line, continuation_lines)
      (["- #{first_line}"] + continuation_lines.map { |line| markdown_continuation_line(line) }).join("\n")
    end

    def markdown_continuation_line(line)
      line.blank? ? '  ' : "  #{line}"
    end
  end

  class << self
    def fetch!(name, category: nil)
      path = resolve(name, category: category)
      raise MissingPromptError, "Prompt not found: #{format_identifier(name, category)}" unless path

      prompt_cache_entry(path)[:content]
    end

    def fetch_task!(name)
      fetch!(name, category: :tasks)
    end

    def render!(name, category: nil, variables: {})
      path = resolve(name, category: category)
      raise MissingPromptError, "Prompt not found: #{format_identifier(name, category)}" unless path

      render_template(
        prompt_cache_entry(path)[:template],
        variables: variables,
        include_snippets: true,
        normalize: category.blank? && %w[assistant scenario].include?(name.to_s)
      )
    end

    def render_inline!(template, variables: {}, include_snippets: false, filters: [])
      render_template(
        Liquid::Template.parse(template, error_mode: :strict),
        variables: variables,
        include_snippets: include_snippets,
        normalize: false,
        filters: filters
      )
    end

    def resolve(name, category: nil)
      candidate_paths(name, category: category).find(&:exist?)
    end

    def clear_cache!
      cache_mutex.synchronize { @prompt_cache = {} }
    end

    private

    def candidate_paths(name, category: nil)
      prompt_name = "#{name}.liquid"
      paths = []

      if category.present?
        paths << ROOT.join(category.to_s, prompt_name)
      else
        paths << ROOT.join(prompt_name)
        paths << ROOT.join('tasks', prompt_name)
      end

      paths.uniq
    end

    def format_identifier(name, category)
      return name.to_s if category.blank?

      "#{category}/#{name}"
    end

    def stringify_keys(hash)
      hash.deep_stringify_keys
    end

    def render_template(liquid_template, variables:, include_snippets:, normalize:, filters: [])
      rendered = liquid_template.render!(
        stringify_keys(variables),
        registers: include_snippets ? { file_system: snippet_file_system } : {},
        filters: [MarkdownFilters, *filters],
        strict_variables: true,
        strict_filters: true
      )

      normalize ? normalize_rendered_prompt(rendered) : rendered
    end

    def normalize_rendered_prompt(prompt)
      prompt.to_s
            .gsub(/\r\n?/, "\n")
            .lines
            .map(&:rstrip)
            .join("\n")
            .gsub(/\n(?=# )/, "\n\n")
            .gsub(/\n{3,}/, "\n\n")
            .strip
    end

    def prompt_cache_entry(path)
      cache_key = path.to_s
      mtime = File.mtime(path).to_f

      cache_mutex.synchronize do
        @prompt_cache ||= {}
        cached_entry = @prompt_cache[cache_key]
        return cached_entry if cached_entry&.dig(:mtime) == mtime

        content = File.read(path)
        @prompt_cache[cache_key] = {
          mtime: mtime,
          content: content,
          template: Liquid::Template.parse(content, error_mode: :strict)
        }
      end
    end

    def cache_mutex
      @cache_mutex ||= Mutex.new
    end

    def snippet_file_system
      @snippet_file_system ||= Liquid::LocalFileSystem.new(snippet_root.to_s, '%s.liquid')
    end

    def snippet_root
      ROOT.join('snippets')
    end
  end
end
