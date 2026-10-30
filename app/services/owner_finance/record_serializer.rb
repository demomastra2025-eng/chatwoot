# frozen_string_literal: true

class OwnerFinance::RecordSerializer
  CATEGORY_LABELS_RU = {
    'client_subscription' => 'Подписки и проекты клиентов',
    'client_delivery' => 'Проекты и внедрение',
    'servers_and_cloud' => 'Серверы, ЦОД и домены',
    'ai_and_llm' => 'ИИ и API провайдеры',
    'telephony' => 'SIP и телефония',
    'partner_commissions' => 'Комиссия МИС МедЭлемент (30%)',
    'payroll_and_contractors' => 'ФОТ и подрядчики',
    'taxes_and_fees' => 'Налоги и комиссии банка',
    'accounting_and_software' => 'Бухгалтерия и ПО (1С)',
    'marketing' => 'Маркетинг и реклама',
    'office_and_ops' => 'Операционные расходы',
    'accountable_transfer' => 'Подотчёт (Счёт ИП ↔ Карта)',
    'unclassified_card' => 'Ожидает разметки с карты'
  }.freeze

  class << self
    def account(acc)
      {
        id: acc.id, name: acc.name, account_kind: acc.account_kind, bank_code: acc.bank_code,
        currency: acc.currency, current_balance: acc.current_balance.to_f,
        balance_kzt: acc.balance_kzt.to_f, scope: acc.scope, active: acc.active, notes: acc.notes
      }
    end

    def deadline(item, reference_date = OwnerFinance.today_almaty)
      {
        id: item.id, title: item.title, category: item.category, payer_mode: item.payer_mode,
        provider: item.provider, related_domain: item.related_domain, client_name: item.client_name,
        contract_id: item.contract_id, due_on: item.due_on.iso8601,
        days_left: item.days_left(reference_date), urgency: item.urgency(reference_date),
        amount: item.amount.to_f, currency: item.currency, amount_kzt: item.amount_kzt.to_f,
        recurrence: item.recurrence, status: item.status, remind_days: item.remind_days, notes: item.notes
      }
    end

    def contract(item, onelink_account = nil)
      contract_core_fields(item).merge(contract_financial_fields(item, onelink_account))
    end

    def transaction(item)
      {
        id: item.id, occurred_on: item.occurred_on.iso8601, direction: item.direction,
        pnl_treatment: item.pnl_treatment, official_status: item.official_status,
        review_status: item.review_status, amount: item.amount.to_f, currency: item.currency,
        amount_kzt: item.amount_kzt.to_f, category: item.category,
        category_label: CATEGORY_LABELS_RU.fetch(item.category, item.category),
        merchant: item.merchant, description: item.description, account_record_id: item.account_record_id
      }
    end

    def obligation(item)
      {
        id: item.id, entry_kind: item.entry_kind, title: item.title,
        counterparty_name: item.counterparty_name, contract_id: item.contract_id,
        period_label: item.period_label, base_amount: item.base_amount.to_f,
        overage_excluded_amount: item.overage_excluded_amount.to_f, amount: item.amount.to_f,
        paid_amount: item.paid_amount.to_f, outstanding_amount: item.outstanding_amount.to_f,
        outstanding_kzt: item.outstanding_kzt.to_f, currency: item.currency,
        due_on: item.due_on&.iso8601, paid_on: item.paid_on&.iso8601, status: item.status, notes: item.notes
      }
    end

    private

    def contract_core_fields(item)
      {
        id: item.id, client_name: item.client_name, contract_number: item.contract_number,
        title: item.title, status: item.status, tariff_code: item.tariff_code,
        billing_day: item.billing_day, starts_on: item.starts_on&.iso8601,
        ends_on: item.ends_on&.iso8601, notes: item.notes
      }
    end

    def contract_financial_fields(item, onelink_account)
      {
        monthly_amount: item.monthly_amount.to_f, monthly_amount_kzt: item.monthly_amount_kzt.to_f,
        one_time_amount: item.one_time_amount.to_f, currency: item.currency,
        medelement_commission_enabled: item.medelement_commission_enabled,
        medelement_commission_rate: item.medelement_commission_rate.to_f,
        medelement_monthly_commission_kzt: item.medelement_monthly_commission_kzt.to_f,
        onelink_account_id: item.onelink_account_id, onelink_account_name: onelink_account&.name
      }
    end
  end
end
