require 'liquid'

class Captain::PromptRegistry
  ROOT = Rails.root.join('enterprise/lib/captain/prompts').freeze

  class MissingPromptError < StandardError; end

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

      render_template(prompt_cache_entry(path)[:template], variables: variables, include_snippets: true)
    end

    def render_inline!(template, variables: {}, include_snippets: false)
      render_template(Liquid::Template.parse(template, error_mode: :strict), variables: variables, include_snippets: include_snippets)
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

    def render_template(liquid_template, variables:, include_snippets:)
      liquid_template.render!(
        stringify_keys(variables),
        registers: include_snippets ? { file_system: snippet_file_system } : {},
        strict_variables: true,
        strict_filters: true
      )
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
