class Whatsapp::UsageCostEstimator
  TEMPLATE_CATEGORIES = %w[marketing utility authentication authentication-international].freeze
  KZ_VAT_RATE = BigDecimal('0.12')
  KZ_VAT_RATE_PERCENT = 12

  def initialize(groups:, month:, exchange_rate:)
    @groups = groups
    @month = month
    @exchange_rate = exchange_rate
  end

  def perform
    totals = category_totals
    overall = totals.values.reduce(empty_totals) do |sum, scope|
      sum.merge(scope) { |_key, left, right| left + right }
    end
    cost_payload(totals, overall)
  end

  private

  def category_totals
    totals = { service: empty_totals, template: empty_totals, other: empty_totals }
    @groups.each do |(category, billable, country), count|
      add_group(totals.fetch(category_scope(category)), category, billable, country, count)
    end
    totals
  end

  def cost_payload(totals, overall)
    service_kzt = amount(totals[:service])
    template_kzt = amount(totals[:template])
    overall_kzt = amount(overall)

    {
      chargeable_service_count: totals[:service][:paid],
      chargeable_template_count: totals[:template][:paid],
      chargeable_message_count: overall[:paid],
      unknown_billable_count: overall[:unknown],
      unpriced_billable_count: overall[:unpriced],
      estimated_amount_usd: usd_amount(overall),
      estimated_service_amount_kzt: service_kzt,
      estimated_template_amount_kzt: template_kzt,
      estimated_amount_kzt: overall_kzt,
      vat_rate_percent: KZ_VAT_RATE_PERCENT,
      estimated_vat_amount_kzt: vat_amount(overall_kzt),
      estimated_service_amount_with_vat_kzt: amount_with_vat(service_kzt),
      estimated_template_amount_with_vat_kzt: amount_with_vat(template_kzt),
      estimated_amount_with_vat_kzt: amount_with_vat(overall_kzt),
      service_cost_complete: complete?(totals[:service]),
      cost_complete: complete?(overall)
    }
  end

  def empty_totals
    { paid: 0, priced: 0, unpriced: 0, unknown: 0, usd: BigDecimal(0) }
  end

  def category_scope(category)
    return :service if category == 'service'

    TEMPLATE_CATEGORIES.include?(category) ? :template : :other
  end

  def add_group(totals, category, billable, country, count)
    if billable.nil?
      totals[:unknown] += count
      return
    end
    return unless billable

    totals[:paid] += count
    rate = Whatsapp::MetaUsdRateCatalog.rate(country_code: country, category: category, at: @month)
    if rate.nil?
      totals[:unpriced] += count
    else
      totals[:priced] += count
      totals[:usd] += rate * count
    end
  end

  def usd_amount(totals)
    return if totals[:priced].zero? && (totals[:unpriced].positive? || totals[:unknown].positive?)
    return BigDecimal(0) if totals[:paid].zero?

    totals[:usd].round(4)
  end

  def amount(totals)
    return if totals[:priced].zero? && (totals[:unpriced].positive? || totals[:unknown].positive?)
    return if totals[:paid].positive? && @exchange_rate.nil?
    return BigDecimal(0) if totals[:paid].zero?

    (totals[:usd] * @exchange_rate.rate_per_usd).round(2)
  end

  def vat_amount(base_amount)
    return if base_amount.nil?

    (base_amount * KZ_VAT_RATE).round(2)
  end

  def amount_with_vat(base_amount)
    return if base_amount.nil?

    (base_amount * (1 + KZ_VAT_RATE)).round(2)
  end

  def complete?(totals)
    totals[:unpriced].zero? && totals[:unknown].zero? && (totals[:paid].zero? || @exchange_rate.present?)
  end
end
