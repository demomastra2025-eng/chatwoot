# frozen_string_literal: true

require 'digest'
require 'json'
require 'yaml'

class Captain::SkillCatalog
  DEFAULT_DIRS = [
    Rails.root.join('config/captain/skills').to_s,
    '/root/.hermes/shared-skills/onelink'
  ].freeze
  SKILL_FILE_NAME = 'SKILL.md'
  MANIFEST_FILE_NAMES = %w[skill.json skill.yml skill.yaml].freeze
  SKIP_DIRS = %w[.git node_modules dist build __pycache__ tmp log].freeze
  MAX_SKILL_BYTES = 200.kilobytes
  MAX_MANIFEST_BYTES = 50.kilobytes
  MAX_TREE_FILE_BYTES = 100.kilobytes
  MAX_TREE_ENTRIES = 200
  MAX_TOOL_ID_LENGTH = 64
  SUPPORTED_SCRIPT_RUNTIMES = %w[ruby node python].freeze

  class << self
    def all(account: nil)
      (account_skills(account) + file_skills)
        .uniq { |skill| skill[:id] }
        .sort_by { |skill| skill_sort_key(skill) }
    end

    def find(id, account: nil)
      all(account: account).find { |skill| skill[:id].to_s == id.to_s }
    end

    def available_ids(account: nil)
      all(account: account).pluck(:id)
    end

    def extract_skill_ids_from_text(text)
      normalized_text =
        case text
        when String
          text
        when Array
          text.flatten.compact.map(&:to_s).join("\n")
        else
          text.to_s
        end

      return [] if normalized_text.blank?

      normalized_text.scan(%r{\[[^\]]+\]\(skill://([^/)]+)\)})
                     .flatten
                     .map { |skill_id| normalize_skill_id(skill_id) }
                     .uniq
    end

    def render_skill_references(text)
      return text if text.blank?

      text.gsub(%r{\[([^\]]+)\]\(skill://([^/)]+)\)}) do
        label = Regexp.last_match(1).to_s.strip
        skill_id = normalize_skill_id(Regexp.last_match(2))
        reference_name = label.presence || skill_id

        "`#{reference_name}` skill"
      end
    end

    def prompt_blocks_for(account:, skill_ids:)
      normalized_ids = Array(skill_ids).map(&:to_s).uniq
      return [] if normalized_ids.empty?

      all(account: account)
        .select { |skill| normalized_ids.include?(skill[:id].to_s) }
        .map do |skill|
          {
            id: skill[:id],
            title: skill[:title],
            description: skill[:description],
            group_name: skill[:group_name],
            content: skill[:content],
            scripts: prompt_script_blocks_for(skill)
          }
        end
    end

    def script_tools_for(account: nil, skill_ids: nil)
      selected_skill_ids = Array(skill_ids).map(&:to_s).presence

      all(account: account)
        .select { |skill| selected_skill_ids.blank? || selected_skill_ids.include?(skill[:id].to_s) }
        .flat_map { |skill| Array(skill[:scripts]) }
        .map { |script| script_tool_definition(script) }
        .uniq { |tool| tool[:id] }
    end

    def script_for_tool_id(tool_id, account: nil)
      all(account: account)
        .flat_map { |skill| Array(skill[:scripts]) }
        .find { |script| script[:tool_id].to_s == tool_id.to_s }
    end

    def script_tool_ids_for(skill_ids:, account: nil)
      script_tools_for(account: account, skill_ids: skill_ids).pluck(:id)
    end

    private

    def file_skills
      Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        skill_dirs.filter_map { |dir| parse_skill_dir(dir) }
                  .uniq { |skill| skill[:id] }
      end
    end

    def account_skills(account)
      return [] unless account&.respond_to?(:captain_skills)

      account.captain_skills.ordered.map(&:to_catalog_entry)
    rescue ActiveRecord::StatementInvalid
      []
    end

    def skill_sort_key(skill)
      [
        skill[:source_type] == 'workspace' ? 0 : 1,
        skill[:group_name].to_s.downcase,
        skill[:title].to_s.downcase
      ]
    end

    def cache_key
      source_state = configured_source_dirs.map do |dir|
        path = Pathname.new(dir)
        next "#{dir}:missing" unless path.directory?

        latest_mtime = path.glob('**/SKILL.md').map { |file| file.mtime.to_i }.max
        "#{dir}:#{latest_mtime}"
      rescue StandardError
        "#{dir}:error"
      end

      ['captain', 'skill_catalog', Digest::SHA256.hexdigest(source_state.join('|'))].join(':')
    end

    def configured_source_dirs
      raw_dirs = ENV.fetch('CAPTAIN_SKILL_DIRS', '').split(':').map(&:presence).compact
      (raw_dirs + DEFAULT_DIRS).uniq
    end

    def skill_dirs
      configured_source_dirs.flat_map do |dir|
        discover_skill_dirs(Pathname.new(dir))
      end
    end

    def discover_skill_dirs(base_path)
      return [] unless base_path.directory?
      return [] unless safe_base_path?(base_path)

      direct = []
      containers = [base_path, base_path.join('skills'), base_path.join('skills/.curated'), base_path.join('skills/.system')]

      containers.each do |container|
        next unless container.directory?

        direct.concat(child_skill_dirs(container))
        child_skill_dirs(container, depth: 2).each { |path| direct << path }
      end

      direct.uniq
    end

    def child_skill_dirs(path, depth: 1)
      return [] if depth.negative? || !path.directory?

      entries = path.children.select(&:directory?).reject { |entry| SKIP_DIRS.include?(entry.basename.to_s) }
      entries.flat_map do |entry|
        current = entry.join(SKILL_FILE_NAME).file? ? [entry] : []
        current + child_skill_dirs(entry, depth: depth - 1)
      end
    rescue StandardError
      []
    end

    def parse_skill_dir(dir)
      skill_path = dir.join(SKILL_FILE_NAME)
      return unless skill_path.file?
      return if skill_path.size > MAX_SKILL_BYTES

      raw = skill_path.read
      frontmatter, content = parse_frontmatter(raw)
      name = sanitize_metadata(frontmatter['name'])
      description = sanitize_metadata(frontmatter['description'])
      return if name.blank? || description.blank?

      {
        id: normalize_skill_id(name),
        title: name,
        description: description,
        group_name: skill_group_name(dir),
        source_path: dir.to_s,
        content: content.to_s.strip,
        scripts: scripts_for(dir, skill_id: normalize_skill_id(name), skill_title: name),
        tree: tree_for(dir),
        editable: false,
        source_type: 'catalog'
      }
    rescue StandardError => e
      Rails.logger.warn("Captain::SkillCatalog failed to parse skill #{dir}: #{e.class} #{e.message}")
      nil
    end

    def parse_frontmatter(raw)
      match = raw.to_s.match(/\A---\r?\n(?<yaml>[\s\S]*?)\r?\n---\r?\n?(?<content>[\s\S]*)\z/)
      return [{}, raw.to_s] unless match

      frontmatter = YAML.safe_load(match[:yaml], aliases: false) || {}
      [frontmatter.is_a?(Hash) ? frontmatter.deep_stringify_keys : {}, match[:content].to_s]
    rescue Psych::Exception
      [{}, raw.to_s]
    end

    def manifest_for(dir)
      manifest_path = MANIFEST_FILE_NAMES.map { |file_name| dir.join(file_name) }.find(&:file?)
      return {} unless manifest_path
      return {} if manifest_path.size > MAX_MANIFEST_BYTES

      case manifest_path.extname
      when '.json'
        JSON.parse(manifest_path.read)
      when '.yml', '.yaml'
        YAML.safe_load(manifest_path.read, aliases: false) || {}
      else
        {}
      end
    rescue JSON::ParserError, Psych::Exception
      {}
    end

    def scripts_for(dir, skill_id:, skill_title:)
      raw_scripts = Array(manifest_for(dir)['scripts'])

      raw_scripts.filter_map do |entry|
        normalize_script_entry(entry, dir: dir, skill_id: skill_id, skill_title: skill_title)
      end
    end

    def normalize_script_entry(entry, dir:, skill_id:, skill_title:)
      raw = entry.respond_to?(:to_h) ? entry.to_h.deep_stringify_keys : {}
      script_id = normalize_script_id(raw['id'].presence || raw['name'])
      command = sanitize_relative_path(raw['command'])
      runtime = raw['runtime'].to_s.presence || runtime_for(command)
      description = sanitize_metadata(raw['description'])
      title = sanitize_metadata(raw['title'].presence || raw['name'].presence || script_id.to_s.humanize)
      risk_level = raw['risk_level'].presence || raw['risk'].presence || 'medium'
      timeout_seconds = if raw['timeout_seconds'].present?
                          [[raw['timeout_seconds'].to_i, 1].max, Captain::SkillScriptRunner::MAX_TIMEOUT_SECONDS].min
                        else
                          Captain::SkillScriptRunner::DEFAULT_TIMEOUT_SECONDS
                        end

      return if script_id.blank? || command.blank?
      return unless SUPPORTED_SCRIPT_RUNTIMES.include?(runtime)
      return unless %w[low medium high].include?(risk_level)

      script_path = dir.join(command)
      return unless script_path.file?
      return unless safe_child_path?(dir.realpath, script_path)

      {
        id: script_id,
        skill_id: skill_id,
        skill_title: skill_title,
        tool_id: script_tool_id(skill_id, script_id),
        title: title,
        description: description.presence || "Run #{title} from #{skill_title}",
        group_name: 'Skill Scripts',
        runtime: runtime,
        command: command,
        source_path: dir.to_s,
        script_path: script_path.to_s,
        risk_level: risk_level,
        requires_confirmation: ActiveModel::Type::Boolean.new.cast(raw.fetch('requires_confirmation', risk_level != 'low')),
        idempotent: ActiveModel::Type::Boolean.new.cast(raw.fetch('idempotent', risk_level == 'low')),
        timeout_seconds: timeout_seconds,
        network: ActiveModel::Type::Boolean.new.cast(raw['network']),
        parameters_schema: normalize_parameters_schema(raw['parameters'] || raw['input_schema'])
      }
    rescue StandardError
      nil
    end

    def script_tool_definition(script)
      {
        id: script[:tool_id],
        title: script[:title],
        description: script[:description],
        group_name: script[:group_name],
        icon: 'terminal-square',
        allowed_scopes: [Captain::ToolAccess::SCOPE_AGENT],
        provider: 'skill_script',
        source_type: Captain::ToolCatalog::SOURCE_TYPE_SKILL,
        skill_id: script[:skill_id],
        skill_script_id: script[:id],
        risk_level: script[:risk_level],
        requires_confirmation: script[:requires_confirmation],
        idempotent: script[:idempotent],
        selected_by_default: false,
        custom: false
      }
    end

    def prompt_script_blocks_for(skill)
      Array(skill[:scripts]).map do |script|
        {
          tool_id: script[:tool_id],
          title: script[:title],
          description: script[:description],
          risk_level: script[:risk_level],
          requires_confirmation: script[:requires_confirmation]
        }
      end
    end

    def tree_for(dir)
      base = dir.realpath
      entries = []

      dir.find.each do |path|
        next if path == dir
        next if path.basename.to_s == SKILL_FILE_NAME && path.file?
        next unless safe_child_path?(base, path)

        relative_path = path.relative_path_from(base).to_s
        next if relative_path.split(File::SEPARATOR).any? { |part| SKIP_DIRS.include?(part) }

        entries << {
          path: relative_path,
          type: path.directory? ? 'directory' : 'file',
          size: (path.file? ? [path.size, MAX_TREE_FILE_BYTES].min : nil)
        }.compact
        break if entries.size >= MAX_TREE_ENTRIES
      end

      entries
    rescue StandardError
      []
    end

    def skill_group_name(dir)
      parent = dir.parent.basename.to_s
      return 'Skills' if parent.blank? || parent == 'skills'

      parent.tr('_-', ' ').titleize
    end

    def script_tool_id(skill_id, script_id)
      suffix = normalize_script_id(script_id)
      digest = Digest::SHA256.hexdigest("#{skill_id}:#{script_id}").slice(0, 12)
      base = "skill_script_#{digest}_#{suffix}".underscore.gsub(/[^a-zA-Z0-9_]/, '_')
      base.slice(0, MAX_TOOL_ID_LENGTH)
    end

    def normalize_script_id(value)
      value.to_s.parameterize.underscore
    end

    def sanitize_relative_path(value)
      path = value.to_s.strip
      return if path.blank? || path.start_with?('/', '~') || path.include?("\0")

      clean = Pathname.new(path).cleanpath.to_s
      return if clean == '.' || clean.start_with?('..')

      clean
    end

    def runtime_for(command)
      case File.extname(command.to_s)
      when '.rb'
        'ruby'
      when '.js', '.mjs'
        'node'
      when '.py'
        'python'
      end
    end

    def normalize_parameters_schema(schema)
      raw_schema = schema.respond_to?(:to_h) ? schema.to_h.deep_stringify_keys : nil
      return default_parameters_schema unless raw_schema.is_a?(Hash)
      return default_parameters_schema unless raw_schema['type'].to_s == 'object'

      raw_schema.slice('type', 'properties', 'required', 'additionalProperties', 'description')
    end

    def default_parameters_schema
      {
        'type' => 'object',
        'properties' => {
          'arguments' => {
            'type' => 'object',
            'description' => 'Structured arguments for the skill script.'
          }
        },
        'additionalProperties' => false
      }
    end

    def normalize_skill_id(value)
      normalized = value.to_s.gsub(/\\(.)/, '\1')
      normalized.parameterize.presence || "skill-#{Digest::SHA256.hexdigest(normalized).slice(0, 12)}"
    end

    def sanitize_metadata(value)
      value.to_s.gsub(/\e\[[\d;]*[A-Za-z]/, '').gsub(/[\r\n]+/, ' ').strip
    end

    def safe_base_path?(path)
      path.cleanpath.to_s.exclude?('..')
    end

    def safe_child_path?(base, path)
      path.realpath.to_s.start_with?("#{base}#{File::SEPARATOR}") || path.realpath == base
    rescue StandardError
      false
    end
  end
end
