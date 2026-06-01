# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'

class Captain::SkillScriptRunner
  DEFAULT_TIMEOUT_SECONDS = 10
  MAX_TIMEOUT_SECONDS = 30
  MAX_OUTPUT_BYTES = 64.kilobytes
  ENABLED_ENV = 'CAPTAIN_SKILL_SCRIPT_EXECUTION_ENABLED'
  NETWORK_ENABLED_ENV = 'CAPTAIN_SKILL_SCRIPT_NETWORK_ENABLED'

  RUNTIME_COMMANDS = {
    'ruby' => [RbConfig.ruby],
    'node' => ['node'],
    'python' => ['python3']
  }.freeze

  def initialize(script:, assistant:, tool_context:, params:)
    @script = script.with_indifferent_access
    @assistant = assistant
    @tool_context = tool_context
    @params = params || {}
  end

  def call
    return disabled_result unless enabled?
    return failure('Skill script is not configured') if script.blank?
    return network_disabled_result if network_requested? && !network_enabled?
    return failure("Unsupported skill script runtime: #{runtime}") unless RUNTIME_COMMANDS.key?(runtime)
    return failure('Skill script path is invalid') unless safe_script_path?

    Dir.mktmpdir("captain-skill-script-#{assistant.id}-") do |workspace|
      execute_in_workspace(workspace)
    end
  rescue Timeout::Error
    failure("Skill script timed out after #{timeout_seconds} seconds")
  rescue StandardError => e
    failure(e)
  end

  private

  attr_reader :script, :assistant, :tool_context, :params

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV[ENABLED_ENV])
  end

  def disabled_result
    failure(
      "Skill script execution is disabled. Set #{ENABLED_ENV}=true only for a dedicated sandboxed worker.",
      retryable: false
    )
  end

  def network_disabled_result
    failure(
      "Skill script network access is disabled. Set #{NETWORK_ENABLED_ENV}=true only in a network-isolated executor.",
      retryable: false
    )
  end

  def execute_in_workspace(workspace)
    stdout, stderr, status = nil

    Timeout.timeout(timeout_seconds) do
      stdout, stderr, status = Open3.capture3(
        sanitized_env(workspace),
        *RUNTIME_COMMANDS.fetch(runtime),
        script_path.to_s,
        stdin_data: JSON.generate(payload),
        chdir: workspace,
        unsetenv_others: true
      )
    end

    output = truncate_output(stdout)
    error_output = truncate_output(stderr)

    return success(output: output, stderr: error_output, exit_status: status.exitstatus) if status.success?

    failure(
      "Skill script exited with status #{status.exitstatus}",
      data: {
        stdout: output,
        stderr: error_output,
        exit_status: status.exitstatus
      },
      retryable: false
    )
  end

  def payload
    {
      params: params,
      context: {
        account_id: assistant.account_id,
        assistant_id: assistant.id,
        conversation_id: state_value(:conversation, :id),
        source: state_root_value(:source)
      }.compact
    }
  end

  def sanitized_env(workspace)
    {
      'HOME' => workspace,
      'PATH' => ENV.fetch('CAPTAIN_SKILL_SCRIPT_PATH', '/usr/local/bin:/usr/bin:/bin'),
      'LANG' => 'C.UTF-8',
      'LC_ALL' => 'C.UTF-8',
      'RAILS_ENV' => Rails.env,
      'SKILL_ID' => script[:skill_id].to_s,
      'SKILL_SCRIPT_ID' => script[:id].to_s,
      'SKILL_DIR' => source_path.to_s,
      'WORKSPACE_DIR' => workspace
    }
  end

  def success(output:, stderr:, exit_status:)
    Captain::ToolResult.success(
      message: output.presence || 'Skill script completed',
      data: {
        stderr: stderr.presence,
        exit_status: exit_status
      }.compact
    )
  end

  def failure(error, data: nil, retryable: nil)
    Captain::ToolResult.failure(error: error, data: data, retryable: retryable)
  end

  def runtime
    script[:runtime].to_s
  end

  def network_requested?
    ActiveModel::Type::Boolean.new.cast(script[:network])
  end

  def network_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV[NETWORK_ENABLED_ENV])
  end

  def script_path
    @script_path ||= Pathname.new(script[:script_path].to_s)
  end

  def source_path
    @source_path ||= Pathname.new(script[:source_path].to_s).realpath
  end

  def safe_script_path?
    return false unless script_path.file?

    real_script_path = script_path.realpath
    real_script_path.to_s.start_with?("#{source_path}#{File::SEPARATOR}")
  rescue StandardError
    false
  end

  def timeout_seconds
    [[script[:timeout_seconds].to_i, 1].max, MAX_TIMEOUT_SECONDS].min
  end

  def truncate_output(output)
    text = Captain::EncodingNormalizer.string(output.to_s)
    return text if text.bytesize <= MAX_OUTPUT_BYTES

    text.byteslice(0, MAX_OUTPUT_BYTES).to_s
  end

  def state_value(group_key, field_key)
    group = tool_context&.state&.[](group_key) || tool_context&.state&.[](group_key.to_s) || {}
    group[field_key] || group[field_key.to_s]
  end

  def state_root_value(key)
    tool_context&.state&.[](key) || tool_context&.state&.[](key.to_s)
  end
end
