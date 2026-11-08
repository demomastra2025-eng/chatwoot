# frozen_string_literal: true

module Reports
  class MonthlyExecutiveReportService
    MONTH_NAMES_RU = {
      1 => 'Январь', 2 => 'Февраль', 3 => 'Март', 4 => 'Апрель',
      5 => 'Май', 6 => 'Июнь', 7 => 'Июль', 8 => 'Август',
      9 => 'Сентябрь', 10 => 'Октябрь', 11 => 'Ноябрь', 12 => 'Декабрь'
    }.freeze

    def initialize(account:, target_month: nil, now: Time.current)
      @account = account
      @now = now
      @timezone = ActiveSupport::TimeZone[account.reporting_timezone.presence || 'Asia/Almaty'] || ActiveSupport::TimeZone['Asia/Almaty']
      @target_date = resolve_target_month(target_month)
    end

    def perform
      month_range = build_month_range(@target_date)
      conversion = Reports::LeadAppointmentsQuery.new(account: account, date_range: month_range, now: now).perform
      dynamics = build_monthly_dynamics(4)

      payload = {
        period_key: @target_date.strftime('%Y-%m'),
        period_label: "#{MONTH_NAMES_RU[@target_date.month]} #{@target_date.year} г.",
        generated_at: now.in_time_zone(@timezone).iso8601,
        account_id: account.id,
        account_name: account.name,
        total_contacts_count: account.contacts.count,
        new_contacts_in_month_count: account.contacts.where(created_at: month_range.from_at...month_range.until_at).count,
        month_conversations_count: account.conversations.where(created_at: month_range.from_at...month_range.until_at).count,
        conversion: conversion,
        monthly_dynamics: dynamics,
        summary_text: build_summary_text(conversion, dynamics, month_range),
        sheet_1_html: build_sheet_1_html(conversion, dynamics),
        sheet_2_html: build_sheet_2_html(conversion)
      }

      persist_to_account!(payload)
      payload
    end

    private

    attr_reader :account, :now, :timezone

    def resolve_target_month(target_month)
      if target_month.is_a?(String) && target_month.match?(/\A\d{4}-\d{2}\z/)
        year, month = target_month.split('-').map(&:to_i)
        Date.new(year, month, 1)
      elsif target_month.respond_to?(:to_date)
        target_month.to_date.beginning_of_month
      else
        now.in_time_zone(@timezone).to_date.prev_month.beginning_of_month
      end
    end

    def build_month_range(month_start_date)
      month_end_date = month_start_date.end_of_month
      Reports::DateRange.new(
        account: account,
        params: { from_date: month_start_date.iso8601, to_date: month_end_date.iso8601 },
        now: now
      )
    end

    def build_monthly_dynamics(months_count)
      (0...months_count).map do |offset|
        m_date = (@target_date << (months_count - 1 - offset)).beginning_of_month
        m_range = build_month_range(m_date)
        res = Reports::LeadAppointmentsQuery.new(account: account, date_range: m_range, now: now).perform
        funnel = res[:all_contacts_funnel] || {}
        {
          period_key: m_date.strftime('%Y-%m'),
          label: "#{MONTH_NAMES_RU[m_date.month]} #{m_date.year}",
          conversations_count: account.conversations.where(created_at: m_range.from_at...m_range.until_at).count,
          contacts_count: funnel[:contacts_count].to_i,
          booked_contacts_count: funnel[:booked_contacts_count].to_i,
          attended_contacts_count: funnel[:attended_contacts_count].to_i,
          booking_conversion_percent: funnel[:booking_conversion_percent].to_f,
          primary_contacts_count: funnel[:primary_contacts_count].to_i,
          repeat_contacts_count: funnel[:repeat_contacts_count].to_i
        }
      end
    end

    def fmt_num(val)
      val.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
    end

    def fmt_pct(val)
      format('%.1f%%', val.to_f).tr('.', ',')
    end

    def build_summary_text(conversion, dynamics, month_range)
      funnel = conversion[:all_contacts_funnel] || {}
      sched = conversion[:schedule_breakdown] || {}
      touches = conversion[:whatsapp_touches] || {}
      period_title = "#{MONTH_NAMES_RU[@target_date.month]} #{@target_date.year} г."
      new_patients = account.contacts.where(created_at: month_range.from_at...month_range.until_at).count
      total_convos = account.conversations.where(created_at: month_range.from_at...month_range.until_at).count

      dyn_lines = dynamics.map do |d|
        "- #{d[:label]}: #{fmt_num(d[:conversations_count])} диалогов | #{fmt_num(d[:contacts_count])} пациентов — #{fmt_num(d[:booked_contacts_count])} записались на приём (#{fmt_pct(d[:booking_conversion_percent])})"
      end.join("\n")

      <<~TEXT.strip
        Сводный отчёт по работе колл-центра и системы OneLink в «#{account.name}» за #{period_title}

        1. ДИНАМИКА ОБРАЩЕНИЙ И КОНВЕРСИИ В ЗАПИСЬ ПО МЕСЯЦАМ
        #{dyn_lines}

        2. ИТОГИ ЗА #{period_title.upcase}
        - Обработано диалогов: #{fmt_num(total_convos)}
        - Уникальных обратившихся пациентов: #{fmt_num(funnel[:contacts_count])} (первичных: #{fmt_num(funnel[:primary_contacts_count])}, повторных: #{fmt_num(funnel[:repeat_contacts_count])})
        - Записались на приём: #{fmt_num(funnel[:booked_contacts_count])} (#{fmt_pct(funnel[:booking_conversion_percent])})
        - Новых карточек пациентов за месяц: #{fmt_num(new_patients)}
        - Автоматические уведомления WhatsApp (всего #{fmt_num(touches[:total_sent_count])}):
          • Напоминание за 1 день (с подтверждением): #{fmt_num(touches[:reminder_1d_sent_count])} (подтверждено #{fmt_pct(touches[:reminder_1d_confirmation_rate_percent])})
          • Напоминание за 2 часа до приёма: #{fmt_num(touches[:reminder_2h_sent_count])}
          • Запрос отзыва после визита: #{fmt_num(touches[:review_request_sent_count])}
        - Расписание, переносы и явка (#{fmt_num(sched[:total_appointments_count])} записей):
          1) Состоявшиеся приёмы: #{fmt_num(sched[:completed_count])} (на сумму #{fmt_num(sched[:completed_revenue_kzt])} ₸)
          2) Переносы записи (±7 дней): #{fmt_num(sched[:rescheduled_count])} (сохранено #{fmt_num(sched[:rescheduled_saved_revenue_kzt])} ₸)
          3) Предварительные отмены (>1 ч до приёма): #{fmt_num(sched[:early_cancelled_count])}
          4) Фактические неявки к часу приёма (No-Show): #{fmt_num(sched[:true_no_show_count])} (упущено #{fmt_num(sched[:true_no_show_lost_revenue_kzt])} ₸)

        Итоговая чистая явка по активному расписанию дня: #{fmt_pct(sched[:net_attendance_rate_percent])}.
      TEXT
    end

    def build_sheet_1_html(conversion, dynamics)
      touches = conversion[:whatsapp_touches] || {}
      rows_html = dynamics.map do |d|
        "<tr><td>#{ERB::Util.html_escape(d[:label])}</td><td class='num'>#{fmt_num(d[:conversations_count])}</td><td class='num'>#{fmt_num(d[:contacts_count])}</td><td class='num'>#{fmt_num(d[:booked_contacts_count])}</td><td class='num'><strong>#{fmt_pct(d[:booking_conversion_percent])}</strong></td></tr>"
      end.join

      <<~HTML
        <!DOCTYPE html>
        <html lang="ru">
        <head><meta charset="utf-8"><title>Отчёт Лист 1 — #{ERB::Util.html_escape(account.name)}</title></head>
        <body style="font-family: Inter, sans-serif; width: 1120px; padding: 40px 48px; color: #1E293B;">
          <h1 style="font-size: 21px; margin-bottom: 16px;">Динамика обращений и авто-касаний — #{ERB::Util.html_escape(account.name)}</h1>
          <table style="width: 100%; border-collapse: collapse; margin-bottom: 24px;">
            <thead><tr><th align="left">Месяц</th><th align="right">Диалогов</th><th align="right">Пациентов</th><th align="right">Записались</th><th align="right">Конверсия</th></tr></thead>
            <tbody>#{rows_html}</tbody>
          </table>
          <h2 style="font-size: 16px; margin-bottom: 8px;">Автоматические уведомления WhatsApp</h2>
          <p>За 1 день: #{fmt_num(touches[:reminder_1d_sent_count])} (подтвердили #{fmt_pct(touches[:reminder_1d_confirmation_rate_percent])}) · За 2 часа: #{fmt_num(touches[:reminder_2h_sent_count])} · Отзывы: #{fmt_num(touches[:review_request_sent_count])}</p>
        </body>
        </html>
      HTML
    end

    def build_sheet_2_html(conversion)
      sched = conversion[:schedule_breakdown] || {}
      period_title = "#{MONTH_NAMES_RU[@target_date.month]} #{@target_date.year} г."
      <<~HTML
        <!DOCTYPE html>
        <html lang="ru">
        <head><meta charset="utf-8"><title>Отчёт Лист 2 — #{ERB::Util.html_escape(account.name)}</title></head>
        <body style="font-family: Inter, sans-serif; width: 1120px; padding: 40px 48px; color: #1E293B;">
          <h1 style="font-size: 21px; margin-bottom: 16px;">Итоги расписания и явки за #{ERB::Util.html_escape(period_title)} — #{ERB::Util.html_escape(account.name)}</h1>
          <ul>
            <li>1. Состоявшиеся приёмы: <strong>#{fmt_num(sched[:completed_count])}</strong> (#{fmt_num(sched[:completed_revenue_kzt])} ₸)</li>
            <li>2. Переносы записи (±7 дней): <strong>#{fmt_num(sched[:rescheduled_count])}</strong> (#{fmt_num(sched[:rescheduled_saved_revenue_kzt])} ₸)</li>
            <li>3. Предварительные отмены: <strong>#{fmt_num(sched[:early_cancelled_count])}</strong></li>
            <li>4. Фактические неявки (No-Show): <strong>#{fmt_num(sched[:true_no_show_count])}</strong> (#{fmt_num(sched[:true_no_show_lost_revenue_kzt])} ₸)</li>
          </ul>
          <p style="margin-top: 16px; font-size: 18px;"><strong>Чистая явка по активному расписанию дня: #{fmt_pct(sched[:net_attendance_rate_percent])}</strong></p>
        </body>
        </html>
      HTML
    end

    def persist_to_account!(payload)
      attrs = account.custom_attributes.to_h.deep_dup
      reports = (attrs['monthly_executive_reports'] || {}).to_h
      reports[payload[:period_key]] = payload.slice(
        :period_key, :period_label, :generated_at,
        :total_contacts_count, :new_contacts_in_month_count, :month_conversations_count,
        :summary_text, :sheet_1_html, :sheet_2_html
      ).merge(
        'schedule_breakdown' => payload.dig(:conversion, :schedule_breakdown),
        'all_contacts_funnel' => payload.dig(:conversion, :all_contacts_funnel),
        'whatsapp_touches' => payload.dig(:conversion, :whatsapp_touches)
      )
      attrs['monthly_executive_reports'] = reports
      attrs['latest_monthly_executive_report_period'] = payload[:period_key]
      account.update_column(:custom_attributes, attrs)
    end
  end
end
