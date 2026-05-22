# frozen_string_literal: true

class Api::V1::Accounts::Captain::EvaluationsController < Api::V1::Accounts::BaseController
  RED_TEAM_PROMPT_MAX_LENGTH = 4_000
  MAX_DATASET_FILES = 5
  MAX_DATASET_FILE_BYTES = 256.kilobytes
  MAX_DATASET_CASES = 50
  MAX_WEB_DATASET_CONCURRENCY = 1

  before_action :check_admin_authorization?

  def show
    render json: {
      packs: Llm::Evals::PackRegistry.catalog,
      eval_runs: eval_run_config,
      tribunal: tribunal_config,
      latest_eval_run: latest_eval_run&.summary
    }
  end

  def run
    pack_ids = requested_pack_ids
    selected_packs = selected_packs_for(pack_ids)

    if queued_run_required?(selected_packs)
      run = Llm::Evals::RunRequest.new(
        account: @current_account,
        user: current_user,
        pack_ids: pack_ids,
        acknowledge_live_cost: params[:acknowledge_llm_cost],
        budget_cents: params[:budget_cents],
        max_cases: params[:max_cases]
      ).call

      render json: {
        packs: Llm::Evals::PackRegistry.catalog,
        eval_runs: eval_run_config,
        run: run.summary
      }, status: :accepted
      return
    end

    result = Llm::Evals::Runner.new(
      account: @current_account,
      pack_ids: pack_ids,
      include_live: false
    ).call

    render json: { packs: Llm::Evals::PackRegistry.catalog, result: result.to_h }
  rescue Llm::Evals::RunRequest::ValidationError => e
    render json: { error: e.message, eval_runs: eval_run_config }, status: :unprocessable_content
  end

  def run_status
    run = Llm::EvalRun.where(account: @current_account).find(params[:run_id])
    render json: { run: run.summary }
  end

  def import_conversation
    exported = Llm::Evals::AiVoiceTraceExporter.new(
      account: @current_account,
      inbox_id: params[:inbox_id],
      display_id: params[:display_id]
    ).call

    render json: exported
  end

  def run_dataset
    files = permitted_dataset_files
    return if performed?

    runner = Llm::Evals::TribunalDatasetRunner.new(
      files: files,
      provider: nil,
      strict: params[:strict],
      threshold: dataset_threshold,
      concurrency: dataset_concurrency,
      allow_live_assertions: params[:allow_live_assertions],
      max_cases: dataset_llm_max_cases
    )
    validate_dataset_file_limits!(runner.files)
    return if performed?

    if ActiveModel::Type::Boolean.new.cast(params[:allow_live_assertions])
      validate_dataset_llm_assertion_budget!(runner.estimated_live_assertion_count)
    end
    result = runner.call
    safe_result = safe_dataset_result(result)
    format = permitted_report_format(params[:format])

    render json: {
      result: safe_result,
      report: safe_dataset_report(safe_result, format),
      format: format,
      files: runner.files.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
    }
  rescue Llm::Evals::RunRequest::ValidationError => e
    render json: { error: e.message, eval_runs: eval_run_config }, status: :unprocessable_content
  end

  def red_team
    prompt = params[:prompt].to_s.strip
    if prompt.blank?
      render json: { error: 'red_team_prompt_required' }, status: :unprocessable_content
      return
    end
    if prompt.length > RED_TEAM_PROMPT_MAX_LENGTH
      render json: { error: 'red_team_prompt_too_long', max_length: RED_TEAM_PROMPT_MAX_LENGTH }, status: :unprocessable_content
      return
    end

    categories = permitted_red_team_categories
    attacks = RubyLLM::Tribunal::RedTeam.generate_attacks(prompt, categories: categories)

    render json: {
      prompt: prompt,
      categories: categories.map(&:to_s),
      attacks: attacks.map { |type, attack_prompt| { type: type.to_s, prompt: attack_prompt } }
    }
  end

  private

  def requested_pack_ids
    ids = Array(params.permit(pack_ids: [])[:pack_ids]).filter_map { |pack_id| pack_id.to_s.presence }
    return ids if ids.present?

    Llm::Evals::PackRegistry.default_packs(include_live: false).map(&:id)
  end

  def selected_packs_for(pack_ids)
    pack_ids.map { |pack_id| Llm::Evals::PackRegistry.find!(pack_id) }
  rescue ArgumentError
    raise Llm::Evals::RunRequest::ValidationError, 'unknown_eval_pack'
  end

  def queued_run_required?(selected_packs)
    selected_packs.any?(&:live_model)
  end

  def eval_run_config
    {
      llm_model_enabled: ActiveModel::Type::Boolean.new.cast(ENV.fetch('LLM_EVALS_LIVE_ENABLED', 'false')),
      max_budget_cents: Llm::Evals::RunRequest::MAX_BUDGET_CENTS,
      default_budget_cents: Llm::Evals::RunRequest::DEFAULT_BUDGET_CENTS,
      max_cases: Llm::Evals::RunRequest::MAX_CASES,
      default_max_cases: Llm::Evals::RunRequest::DEFAULT_MAX_CASES,
      estimated_llm_case_cost_cents: Llm::Evals::RunRequest::ESTIMATED_LLM_CASE_COST_CENTS
    }
  end

  def validate_dataset_llm_assertion_budget!(live_assertion_count)
    budget_cents = dataset_llm_budget_cents
    max_cases = dataset_llm_max_cases
    estimated_units = [live_assertion_count, max_cases].max
    estimated_cost = estimated_units * Llm::Evals::RunRequest::ESTIMATED_LLM_CASE_COST_CENTS

    raise Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_runs_disabled' unless eval_run_config[:llm_model_enabled]
    unless ActiveModel::Type::Boolean.new.cast(params[:acknowledge_llm_cost])
      raise Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_cost_acknowledgement_required'
    end
    raise Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_budget_exceeded' if budget_cents > Llm::Evals::RunRequest::MAX_BUDGET_CENTS
    raise Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_case_limit_exceeded' if max_cases > Llm::Evals::RunRequest::MAX_CASES
    raise Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_budget_exceeded' if estimated_cost > budget_cents
  end

  def dataset_llm_budget_cents
    normalized_positive_integer(params[:budget_cents], Llm::Evals::RunRequest::DEFAULT_BUDGET_CENTS)
  end

  def dataset_llm_max_cases
    normalized_positive_integer(params[:max_cases], Llm::Evals::RunRequest::DEFAULT_MAX_CASES)
  end

  def normalized_positive_integer(value, fallback)
    normalized = value.to_i
    normalized.positive? ? normalized : fallback
  end

  def latest_eval_run
    Llm::EvalRun.where(account: @current_account).recent.first
  end

  def tribunal_config
    Llm::Evals::TribunalConfig.apply!

    {
      available_assertions: RubyLLM::Tribunal.available_assertions.map(&:to_s),
      judge_names: RubyLLM::Tribunal.judge_names.map(&:to_s),
      report_formats: RubyLLM::Tribunal::Reporter.available_formats.map(&:to_s),
      red_team_categories: RubyLLM::Tribunal::RedTeam::CATEGORIES.map(&:to_s),
      max_concurrency: Llm::Evals::TribunalDatasetRunner::MAX_CONCURRENCY,
      dataset_patterns: Llm::Evals::TribunalDatasetRunner::DEFAULT_PATTERNS.map do |pattern|
        Pathname.new(pattern).relative_path_from(Rails.root).to_s
      end
    }
  end

  def permitted_report_format(format)
    normalized = format.to_s.presence || 'console'
    allowed = RubyLLM::Tribunal::Reporter.available_formats.map(&:to_s)
    allowed.include?(normalized) ? normalized.to_sym : :console
  end

  def permitted_dataset_files
    requested = Array(params[:files]).flat_map { |value| value.to_s.split(',') }.filter_map { |value| value.strip.presence }
    return nil if requested.blank?

    if requested.size > MAX_DATASET_FILES
      render json: { error: 'dataset_file_limit_exceeded', max_files: MAX_DATASET_FILES }, status: :unprocessable_content
      return
    end

    invalid_path = requested.find { |path| !permitted_dataset_path?(Rails.root.join(path).cleanpath) }
    if invalid_path
      render json: { error: 'invalid_dataset_file', file: invalid_path }, status: :unprocessable_content
      return
    end

    requested.map { |path| Rails.root.join(path).cleanpath.to_s }
  end

  def permitted_dataset_path?(path)
    allowed_extension = %w[.json .yaml .yml].include?(path.extname.downcase)
    return false unless allowed_extension && path.file?

    real_path = path.realpath
    Llm::Evals::TribunalDatasetRunner::DEFAULT_DATASET_ROOTS.any? do |root|
      real_path.to_s.start_with?(root.realpath.to_s + File::SEPARATOR)
    end
  rescue Errno::ENOENT, ArgumentError
    false
  end

  def validate_dataset_file_limits!(files)
    if files.size > MAX_DATASET_FILES
      render json: { error: 'dataset_file_limit_exceeded', max_files: MAX_DATASET_FILES }, status: :unprocessable_content
      return
    end

    invalid_path = files.find { |path| !permitted_dataset_path?(Pathname.new(path)) }
    if invalid_path
      render json: { error: 'invalid_dataset_file', file: relative_dataset_path(invalid_path) }, status: :unprocessable_content
      return
    end

    oversized_path = files.find { |path| File.size(path) > MAX_DATASET_FILE_BYTES }
    if oversized_path
      render json: { error: 'dataset_file_too_large', file: relative_dataset_path(oversized_path), max_bytes: MAX_DATASET_FILE_BYTES },
             status: :unprocessable_content
      return
    end

    case_count = files.sum { |path| dataset_case_count(path) }
    return unless case_count > MAX_DATASET_CASES

    render json: { error: 'dataset_case_limit_exceeded', max_cases: MAX_DATASET_CASES }, status: :unprocessable_content
  end

  def relative_dataset_path(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  rescue ArgumentError
    path.to_s
  end

  def dataset_case_count(path)
    payload = YAML.safe_load_file(path, aliases: true) || {}
    cases = payload.is_a?(Hash) ? payload.fetch('cases', []) : payload
    Array(cases).size
  end

  def dataset_threshold
    value = params[:threshold].to_s.strip
    return if value.blank?

    value.to_f.clamp(0.0, 1.0)
  end

  def dataset_concurrency
    value = params[:concurrency].to_i
    return 1 unless value.positive?

    [value, MAX_WEB_DATASET_CONCURRENCY].min
  end

  def safe_dataset_result(result)
    summary = result.fetch(:summary, result['summary'] || {})
    metrics = result.fetch(:metrics, result['metrics'] || {})

    {
      summary: summary,
      metrics: Llm::EvalRun.sanitize_result(metrics)
    }
  end

  def safe_dataset_report(result, format)
    summary = result.fetch(:summary, {})
    return JSON.pretty_generate(result) if format.to_sym == :json

    [
      "status=#{summary[:threshold_passed] ? 'passed' : 'failed'}",
      "total=#{summary[:total]}",
      "passed=#{summary[:passed]}",
      "failed=#{summary[:failed]}",
      "pass_rate=#{summary[:pass_rate]}",
      "duration_ms=#{summary[:duration_ms]}"
    ].join("\n")
  end

  def permitted_red_team_categories
    requested = Array(params[:categories]).filter_map { |category| category.to_s.presence&.to_sym }
    allowed = RubyLLM::Tribunal::RedTeam::CATEGORIES
    categories = requested.presence || allowed
    categories & allowed
  end
end
