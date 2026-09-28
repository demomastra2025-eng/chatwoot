class Scheduling::Appointments::RetiredFinanceGuard
  RETIRED_FINANCE_PARAMS = %w[
    service_amount prepaid_amount prepaid_payment_method settlement_amount settlement_payment_method payment_status
    compensation_type_snapshot compensation_value_snapshot compensation_percent_snapshot
  ].freeze
  RETIRED_FINANCE_MESSAGE = 'Эта версия формы записи устарела. Денежные поля не сохранены. ' \
                            'Скопируйте нужные неденежные данные до ручного обновления вкладки ' \
                            'и внесите их заново без аванса и ручной цены.'.freeze

  def self.reject_fields!(params)
    payloads = [params, params[:appointment] || params['appointment']].select { |payload| payload.respond_to?(:keys) }
    return unless payloads.any? { |payload| payload.keys.map(&:to_s).intersect?(RETIRED_FINANCE_PARAMS) }

    raise Scheduling::Error.new(
      code: 'RETIRED_FINANCE_FIELDS', message: RETIRED_FINANCE_MESSAGE, status: :unprocessable_content
    )
  end

  def self.reject_mutation!
    raise Scheduling::Error.new(
      code: 'RETIRED_FINANCE_MUTATION',
      message: 'Оплата и расходы записи больше не редактируются. Данные не изменены. Обновите вкладку.',
      status: :unprocessable_content
    )
  end
end
