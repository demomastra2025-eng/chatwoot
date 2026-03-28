require 'liquid'

class Captain::PromptRenderer
  class << self
    def render(template_name, context = {})
      template = load_template(template_name)
      liquid_template = Liquid::Template.parse(template, error_mode: :strict)
      liquid_template.render!(
        stringify_keys(context),
        registers: { file_system: snippet_file_system }
      )
    end

    private

    def load_template(template_name)
      template_path = Rails.root.join('enterprise', 'lib', 'captain', 'prompts', "#{template_name}.liquid")

      raise "Template not found: #{template_name}" unless File.exist?(template_path)

      File.read(template_path)
    end

    def stringify_keys(hash)
      hash.deep_stringify_keys
    end

    def snippet_file_system
      @snippet_file_system ||= Liquid::LocalFileSystem.new(snippet_root.to_s, '%s.liquid')
    end

    def snippet_root
      Rails.root.join('enterprise', 'lib', 'captain', 'prompts', 'snippets')
    end
  end
end
