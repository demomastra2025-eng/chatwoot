class Crm::Deals::ExportStageAnalytics
  OUTCOME_LABELS = {
    'open' => 'В работе',
    'won' => 'Успешно реализовано',
    'lost' => 'Закрыто и не реализовано'
  }.freeze
  TERMINAL_OUTCOMES = %w[won lost].freeze

  STAGE_SUMMARY_HEADERS = [
    'Посещено этапов',
    'Кол-во переходов между этапами',
    'Время на текущем этапе (мин)',
    'Общее время в воронке (мин)',
    'Маршрут по этапам (история и длительность)'
  ].freeze

  STAGE_VISITS_SHEET_HEADERS = [
    'ID сделки',
    'Название сделки',
    'Воронка',
    'Этап',
    'Исход этапа',
    'Вход на этап',
    'Выход с этапа',
    'Длительность (сек)',
    'Длительность (мин)',
    'Активный этап'
  ].freeze

  def initialize(account:, deals:, exported_at:, timezone:)
    @account = account
    @deals = deals
    @exported_at = exported_at
    @timezone = timezone
  end

  def duration_headers
    stage_duration_columns.pluck(:header)
  end

  def deal_stage_values(deal)
    stats = analyze_visits(ordered_visits(deal))
    [
      stats[:visited_count],
      stats[:transitions_count],
      stats[:current_stage_minutes],
      stats[:total_minutes],
      stats[:route_summary]
    ] + stage_duration_values(stats)
  end

  def visits_sheet_rows
    rows = [STAGE_VISITS_SHEET_HEADERS]
    deals.each do |deal|
      ordered_visits(deal).each { |visit| rows << visit_sheet_row(deal, visit) }
    end
    rows
  end

  def format_time(value)
    return '' if value.blank?

    value.in_time_zone(timezone).strftime('%Y-%m-%d %H:%M:%S')
  end

  private

  attr_reader :account, :deals, :exported_at, :timezone

  def visit_sheet_row(deal, visit)
    seconds = visit_duration_seconds(visit)
    [
      deal.id,
      deal.title,
      visit.pipeline_name.presence || deal.pipeline&.name.to_s,
      visit.stage_name,
      OUTCOME_LABELS.fetch(visit.stage_outcome.to_s, visit.stage_outcome.to_s),
      format_time(visit.entered_at),
      format_time(visit.exited_at),
      seconds,
      (seconds / 60.0).round(1),
      ongoing_open_visit?(visit) ? 'Да' : 'Нет'
    ]
  end

  def analyze_visits(visits)
    by_id = Hash.new(0)
    by_name = Hash.new(0)
    route_parts = accumulate_visit_durations(visits, by_id, by_name)
    total_sec = by_name.values.sum
    current_sec = active_visit_seconds(visits)
    {
      visited_count: visits.size,
      transitions_count: [visits.size - 1, 0].max,
      current_stage_minutes: (current_sec / 60.0).round(1),
      total_minutes: (total_sec / 60.0).round(1),
      route_summary: route_parts.join(' → '),
      seconds_by_stage_id: by_id,
      seconds_by_stage_name: by_name
    }
  end

  def accumulate_visit_durations(visits, by_id, by_name)
    visits.map do |visit|
      sec = visit_duration_seconds(visit)
      by_id[visit.stage_id] += sec if visit.stage_id.present?
      by_name[[visit.pipeline_name.to_s, visit.stage_name.to_s]] += sec
      "#{visit.stage_name} (#{(sec / 60.0).round(1)} мин)"
    end
  end

  def active_visit_seconds(visits)
    target = visits.reverse.find { |visit| ongoing_open_visit?(visit) }
    target ? visit_duration_seconds(target) : 0
  end

  def ongoing_open_visit?(visit)
    visit.active? && TERMINAL_OUTCOMES.exclude?(visit.stage_outcome.to_s)
  end

  def stage_duration_values(stats)
    stage_duration_columns.map do |col|
      seconds = col[:stage_id] ? stats[:seconds_by_stage_id][col[:stage_id]].to_i : stats[:seconds_by_stage_name][col[:name_key]].to_i
      seconds.positive? ? (seconds / 60.0).round(1) : 0
    end
  end

  def stage_duration_columns
    @stage_duration_columns ||= build_stage_duration_columns
  end

  def build_stage_duration_columns
    pipeline_ids = deals.filter_map(&:pipeline_id).uniq
    multi = pipeline_ids.size > 1
    stages = account.crm_stages.includes(:pipeline).where(pipeline_id: pipeline_ids).order(:pipeline_id, :position, :id).to_a
    known_ids = stages.to_set(&:id)
    stage_columns_for_active(stages, multi) + stage_columns_for_detached(known_ids, multi)
  end

  def stage_columns_for_active(stages, multi)
    stages.map do |stage|
      p_name = stage.pipeline&.name.to_s
      { stage_id: stage.id, name_key: [p_name, stage.name.to_s], header: stage_duration_header(p_name, stage.name, multi) }
    end
  end

  def stage_columns_for_detached(known_ids, multi)
    detached_visit_keys(known_ids).map do |p_name, s_name|
      { stage_id: nil, name_key: [p_name, s_name], header: stage_duration_header(p_name, s_name, multi) }
    end
  end

  def detached_visit_keys(known_ids)
    deals.flat_map { |deal| ordered_visits(deal) }
         .reject { |visit| visit.stage_id.present? && known_ids.include?(visit.stage_id) }
         .map { |visit| [visit.pipeline_name.to_s, visit.stage_name.to_s] }
         .uniq
  end

  def stage_duration_header(pipeline_name, stage_name, multi)
    prefix = multi && pipeline_name.present? ? "#{pipeline_name} / " : ''
    "Длительность: #{prefix}#{stage_name} (мин)"
  end

  def ordered_visits(deal)
    epoch = Time.zone.at(0)
    deal.stage_visits.sort_by { |visit| [visit.entered_at || epoch, visit.id.to_i] }
  end

  def visit_duration_seconds(visit)
    return 0 if visit.entered_at.blank?
    return 0 if visit.exited_at.nil? && TERMINAL_OUTCOMES.include?(visit.stage_outcome.to_s)

    [((visit.exited_at || exported_at) - visit.entered_at).to_i, 0].max
  end
end
