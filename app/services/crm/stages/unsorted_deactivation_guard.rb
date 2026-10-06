class Crm::Stages::UnsortedDeactivationGuard
  def self.ensure_empty!(stage)
    return unless stage.technical_stage?

    count = stage.deals.count
    return if count.zero?

    raise Crm::Error.new(
      code: 'UNSORTED_STAGE_HAS_DEALS',
      message: "В «Неразобранном» есть сделки (#{count}). Перенесите их в другой этап перед отключением.",
      status: :unprocessable_content,
      details: { stage_id: stage.id, deal_count: count }
    )
  end
end
