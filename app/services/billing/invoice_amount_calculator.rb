# frozen_string_literal: true

class Billing::InvoiceAmountCalculator
  DEFAULT_STORAGE_PACK_KZT = 3000

  Result = Struct.new(
    :plan_key, :usage_period_month, :base_amount_minor, :addons_amount_minor,
    :ai_dialogs_overage_count, :ai_dialogs_overage_minor,
    :call_minutes_overage_count, :call_minutes_overage_minor,
    :amount_minor, :partner_commission_base_minor, :line_items,
    keyword_init: true
  )

  def initialize(account:, profile:, period_start:, period_end: nil, usage_period_month: nil)
    @account = account
    @profile = profile
    @period_start = period_start
    @period_end = period_end || profile.next_period_end_from(period_start)
    @explicit_usage_month = usage_period_month
  end

  def perform
    base_minor = compute_base_amount_minor
    seats_minor, storage_minor = compute_addon_amounts_minor
    addons_minor = seats_minor + storage_minor
    overage = compute_overage_details
    total_minor = base_minor + addons_minor + overage[:dialogs_minor] + overage[:minutes_minor]

    Result.new(
      plan_key: resolved_plan_key,
      usage_period_month: overage[:period_month],
      base_amount_minor: base_minor,
      addons_amount_minor: addons_minor,
      ai_dialogs_overage_count: overage[:dialogs_count],
      ai_dialogs_overage_minor: overage[:dialogs_minor],
      call_minutes_overage_count: overage[:minutes_count],
      call_minutes_overage_minor: overage[:minutes_minor],
      amount_minor: total_minor,
      partner_commission_base_minor: base_minor,
      line_items: build_line_items(base_minor, seats_minor, storage_minor, overage)
    )
  end

  private

  def resolved_plan_key
    @resolved_plan_key ||= begin
      attrs = @account.custom_attributes.to_h
      Accounts::Plans.stored_tariff(attrs[Accounts::ApplyPlan::TARIFF_KEY]) ||
        Accounts::Plans.stored_tariff(attrs['plan_name'])
    end
  end

  def tariff_pricing
    @tariff_pricing ||= resolved_plan_key ? Accounts::Plans.tariff_pricing(resolved_plan_key) : {}
  end

  def compute_base_amount_minor
    return @profile.custom_monthly_price_minor.to_i if @profile.custom_monthly_price_minor.present?

    price_key = @profile.annual_discount? ? 'annual_monthly_kzt' : 'monthly_kzt'
    kzt = tariff_pricing[price_key] || tariff_pricing['monthly_kzt']
    raise ArgumentError, "Base monthly price is not configured for account ##{@account.id} (plan=#{resolved_plan_key || 'none'})" if kzt.blank?

    Billing.kzt_to_minor(kzt)
  end

  def compute_addon_amounts_minor
    seat_unit_kzt = tariff_pricing['extra_agent_kzt'] || @profile.metadata.to_h['extra_agent_kzt'] || 0
    storage_unit_kzt = tariff_pricing['extra_storage_10gb_kzt'] || @profile.metadata.to_h['extra_storage_10gb_kzt'] || DEFAULT_STORAGE_PACK_KZT
    seats_minor = @profile.extra_seats_count.to_i * Billing.kzt_to_minor(seat_unit_kzt)
    storage_minor = @profile.extra_storage_packs_count.to_i * Billing.kzt_to_minor(storage_unit_kzt)
    [seats_minor, storage_minor]
  end

  def compute_overage_details
    month_key = resolve_usage_period_month
    return zero_overage(nil) if month_key.blank?

    usage_time = parse_usage_month_time(month_key)
    svc = Accounts::MonthlyAiUsageService.new(@account)
    dialogs_over = overage_units(:captain_ai_dialogs, svc.ai_dialogs_consumed(at: usage_time))
    minutes_over = overage_units(:call_analysis_minutes, svc.call_analysis_minutes_consumed(at: usage_time))
    build_overage_hash(month_key, dialogs_over, minutes_over)
  end

  def build_overage_hash(month_key, dialogs_over, minutes_over)
    dialog_kzt = tariff_pricing['overage_ai_dialog_kzt'] || Accounts::MonthlyAiUsageService::OVERAGE_AI_DIALOG_KZT
    minute_kzt = tariff_pricing['overage_call_minute_kzt'] || Accounts::MonthlyAiUsageService::OVERAGE_CALL_MINUTE_KZT
    {
      period_month: month_key,
      dialogs_count: dialogs_over,
      dialogs_unit_minor: Billing.kzt_to_minor(dialog_kzt),
      dialogs_minor: dialogs_over * Billing.kzt_to_minor(dialog_kzt),
      minutes_count: minutes_over,
      minutes_unit_minor: Billing.kzt_to_minor(minute_kzt),
      minutes_minor: minutes_over * Billing.kzt_to_minor(minute_kzt)
    }
  end

  def zero_overage(month_key)
    {
      period_month: month_key, dialogs_count: 0, dialogs_unit_minor: 0, dialogs_minor: 0,
      minutes_count: 0, minutes_unit_minor: 0, minutes_minor: 0
    }
  end

  def resolve_usage_period_month
    return @explicit_usage_month if @explicit_usage_month.present?

    candidate = (@period_start.beginning_of_month - 1.day).strftime('%Y-%m')
    already_billed = Billing::Invoice.where(account_id: @account.id, usage_period_month: candidate)
                                     .where.not(status: 'cancelled').exists?
    already_billed ? nil : candidate
  end

  def parse_usage_month_time(month_key)
    year, month = month_key.split('-').map(&:to_i)
    Time.find_zone(Billing::ALMATY_TIMEZONE).local(year, month, 15, 12, 0, 0)
  end

  def overage_units(limit_sym, consumed)
    quota, unlimited = included_quota_for(limit_sym.to_s)
    return 0 if unlimited

    [consumed.to_i - quota, 0].max
  end

  def included_quota_for(key)
    raw = @account.limits.to_h[key]
    return [raw.to_i, Accounts::Plans.unlimited_value?(key, raw.to_i)] if raw.present?
    return [0, false] if resolved_plan_key.blank?

    plan_val = Accounts::Plans.limits_for([], tariff: resolved_plan_key)[key].to_i
    [plan_val, Accounts::Plans.unlimited_value?(key, plan_val)]
  end

  def build_line_items(base_minor, seats_minor, storage_minor, overage)
    items = [base_line_item(base_minor)]
    append_addon_line_items(items, seats_minor, storage_minor)
    append_overage_line_items(items, overage)
    items
  end

  def base_line_item(base_minor)
    label = resolved_plan_key ? Accounts::Plans.tariff_name(resolved_plan_key) : 'Индивидуальный'
    period_str = "#{@period_start.strftime('%d.%m.%Y')} - #{@period_end.strftime('%d.%m.%Y')}"
    {
      'code' => 'subscription_base',
      'description' => "Доступ к платформе OneLink (тариф #{label}, период #{period_str})",
      'quantity' => 1, 'unit_price_minor' => base_minor, 'amount_minor' => base_minor
    }
  end

  def append_addon_line_items(items, seats_minor, storage_minor)
    if seats_minor.positive?
      count = @profile.extra_seats_count.to_i
      items << {
        'code' => 'extra_seats', 'description' => 'Дополнительные рабочие места операторов',
        'quantity' => count, 'unit_price_minor' => seats_minor / count, 'amount_minor' => seats_minor
      }
    end
    return unless storage_minor.positive?

    packs = @profile.extra_storage_packs_count.to_i
    items << {
      'code' => 'extra_storage', 'description' => 'Дополнительное хранилище (+10 ГБ)',
      'quantity' => packs, 'unit_price_minor' => storage_minor / packs, 'amount_minor' => storage_minor
    }
  end

  def append_overage_line_items(items, overage)
    if overage[:dialogs_minor].positive?
      items << {
        'code' => 'ai_dialogs_overage',
        'description' => "Сверхлимитные ИИ-диалоги за #{overage[:period_month]}",
        'quantity' => overage[:dialogs_count], 'unit_price_minor' => overage[:dialogs_unit_minor],
        'amount_minor' => overage[:dialogs_minor]
      }
    end
    return unless overage[:minutes_minor].positive?

    items << {
      'code' => 'call_minutes_overage',
      'description' => "Сверхлимитные минуты ИИ-разбора звонков за #{overage[:period_month]}",
      'quantity' => overage[:minutes_count], 'unit_price_minor' => overage[:minutes_unit_minor],
      'amount_minor' => overage[:minutes_minor]
    }
  end
end
