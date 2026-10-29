require 'csv'

class Crm::Deals::ExportService
  UTF8_BOM = "\xEF\xBB\xBF".freeze
  OUTCOME_LABELS = Crm::Deals::ExportStageAnalytics::OUTCOME_LABELS

  STANDARD_HEADERS = [
    'ID сделки', 'Название', 'Воронка', 'Текущий этап', 'Исход этапа', 'Статус', 'Сумма', 'Валюта',
    'Ответственный', 'Команда', 'Компания', 'Контакт (пациент)', 'Телефон контакта', 'Email контакта',
    'ИИН контакта', 'ID диалога', 'Дата создания', 'Ожидаемая дата закрытия', 'Дата закрытия', 'Причины закрытия'
  ].freeze

  def initialize(account:, deals:, account_user: Current.account_user, exported_at: Time.current)
    @account = account
    @deals = Array(deals)
    @account_user = account_user
    @timezone = Time.find_zone!(Crm::WorkspaceTimezone.resolve(account))
    @stage_analytics = Crm::Deals::ExportStageAnalytics.new(
      account: account,
      deals: @deals,
      exported_at: exported_at,
      timezone: @timezone
    )
  end

  def to_csv
    csv_body = CSV.generate do |csv|
      deals_sheet_rows.each do |row|
        csv << row.map { |cell| sanitize_csv_cell(cell) }
      end
    end
    "#{UTF8_BOM}#{csv_body}"
  end

  def to_xlsx
    Crm::Deals::XlsxBuilder.build(
      [
        { name: 'Сделки', rows: deals_sheet_rows },
        { name: 'История этапов', rows: stage_analytics.visits_sheet_rows }
      ]
    )
  end

  private

  attr_reader :account, :deals, :account_user, :stage_analytics

  def deals_sheet_rows
    headers = STANDARD_HEADERS + custom_field_columns.pluck(:header) +
              Crm::Deals::ExportStageAnalytics::STAGE_SUMMARY_HEADERS + stage_analytics.duration_headers
    [headers] + deals.map { |deal| build_deal_row(deal) }
  end

  def build_deal_row(deal)
    contact = resolve_primary_contact(deal)
    standard_values(deal, contact) + custom_attribute_values(deal) + stage_analytics.deal_stage_values(deal)
  end

  def standard_values(deal, contact)
    deal_core_values(deal) + deal_relation_values(deal) + deal_contact_values(contact) + deal_lifecycle_values(deal)
  end

  def deal_core_values(deal)
    outcome = deal.stage&.outcome.to_s
    [
      deal.id,
      deal.title,
      deal.pipeline&.name.to_s,
      deal.stage&.name.to_s,
      OUTCOME_LABELS.fetch(outcome, outcome),
      deal_status_label(deal),
      major_amount(deal),
      deal.currency.to_s
    ]
  end

  def deal_relation_values(deal)
    [
      deal.owner&.name.presence || deal.owner&.email.to_s,
      deal.team&.name.to_s,
      deal.company&.name.to_s
    ]
  end

  def deal_contact_values(contact)
    full_name = contact ? [contact.name, contact.last_name, contact.middle_name].compact_blank.join(' ') : ''
    [
      full_name,
      contact&.phone_number.to_s,
      contact&.email.to_s,
      Contacts::IinPrivacy.contact_iin_for_export(contact, account_user: account_user)
    ]
  end

  def deal_lifecycle_values(deal)
    reasons = deal.stage&.outcome_lost? ? Array(deal.closing_reasons).join('; ') : ''
    [
      dialog_display_id(deal),
      stage_analytics.format_time(deal.created_at),
      deal.expected_close_on&.iso8601.to_s,
      stage_analytics.format_time(deal.closed_at),
      reasons
    ]
  end

  def custom_attribute_values(deal)
    attrs = deal.custom_attributes.to_h
    custom_field_columns.map { |col| format_custom_value(attrs[col[:key]], col[:definition]) }
  end

  def custom_field_columns
    @custom_field_columns ||= build_custom_field_columns
  end

  def build_custom_field_columns
    definitions = account.crm_field_definitions.where(entity_kind: 'deal').order(:position, :id).to_a
    defined_cols = definitions.map { |defn| { key: defn.key, header: "#{defn.label} (#{defn.key})", definition: defn } }
    extra_keys = deals.flat_map { |deal| deal.custom_attributes.to_h.keys.map(&:to_s) }.uniq - definitions.map(&:key)
    defined_cols + extra_keys.sort.map { |key| { key: key, header: key, definition: nil } }
  end

  def format_custom_value(raw_value, definition)
    return '' if raw_value.nil? || raw_value == ''

    format_typed_value(raw_value, definition)
  end

  FIELD_FORMATTERS = {
    'checkbox' => :format_checkbox_value,
    'select' => :format_select_value,
    'multiselect' => :format_multiselect_value,
    'number' => :format_numeric_value,
    'currency' => :format_numeric_value,
    'percent' => :format_numeric_value
  }.freeze

  def format_typed_value(raw_value, definition)
    formatter = FIELD_FORMATTERS[definition&.field_type]
    return send(formatter, raw_value, definition) if formatter

    raw_value.is_a?(Array) ? raw_value.join('; ') : raw_value.to_s
  end

  def format_checkbox_value(raw_value, _definition)
    ActiveModel::Type::Boolean.new.cast(raw_value) ? 'Да' : 'Нет'
  end

  def format_select_value(raw_value, definition)
    option_label(definition, raw_value)
  end

  def format_multiselect_value(raw_value, definition)
    Array(raw_value).map { |item| option_label(definition, item) }.join('; ')
  end

  def format_numeric_value(raw_value, _definition)
    numeric_or_string(raw_value)
  end

  def option_label(definition, value)
    target = value.to_s
    match = Array(definition&.options).find { |opt| option_field(opt, 'value') == target }
    option_field(match, 'label').presence || target
  end

  def option_field(opt, name)
    return '' unless opt.respond_to?(:[])

    (opt[name] || opt[name.to_sym]).to_s
  end

  def numeric_or_string(value)
    return value if value.is_a?(Integer) || value.is_a?(Float)

    Float(value.to_s)
  rescue ArgumentError, TypeError
    value.to_s
  end

  def resolve_primary_contact(deal)
    deal.deal_contacts.detect(&:primary?)&.contact || deal.deal_contacts.first&.contact
  end

  def major_amount(deal)
    return '' if deal.amount_minor.nil?

    minor = deal.amount_minor.to_i
    (minor % 100).zero? ? (minor / 100) : (minor / 100.0).round(2)
  end

  def deal_status_label(deal)
    return 'В архиве' if deal.archived_at.present?
    return 'Закрыта' if deal.closed?
    return 'Ожидание' if deal.waiting?

    'Активна'
  end

  def dialog_display_id(deal)
    deal.originating_communication_thread&.display_id || deal.originating_conversation&.display_id || ''
  end

  def sanitize_csv_cell(value)
    return value unless value.is_a?(String)

    value.match?(Crm::Deals::XlsxBuilder::FORMULA_PREFIX_REGEX) ? "'#{value}" : value
  end
end
