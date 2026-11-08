module Reports
  class LeadAppointmentsQuery
    MAX_BREAKDOWN_ROWS = 20

    COHORT_SQL = <<~SQL.squish.freeze
      WITH period_contacts AS (
        SELECT DISTINCT ON (conversations.contact_id)
          conversations.contact_id,
          messages.created_at AS first_inbound_at,
          messages.id AS message_id,
          messages.inbox_id,
          NOT EXISTS (
            SELECT 1 FROM conversations previous_conversation
            JOIN messages previous_message ON previous_message.conversation_id = previous_conversation.id
            WHERE previous_conversation.account_id = $1 AND previous_conversation.contact_id = conversations.contact_id
              AND previous_message.account_id = $1 AND previous_message.message_type = 0 AND NOT previous_message.private
              AND (previous_message.created_at, previous_message.id) < (messages.created_at, messages.id)
          ) AS is_new_lead
        FROM messages JOIN conversations ON conversations.id = messages.conversation_id AND conversations.account_id = $1
        WHERE messages.account_id = $1 AND messages.message_type = 0 AND NOT messages.private
          AND messages.created_at >= $2 AND messages.created_at < $3
        ORDER BY conversations.contact_id, messages.created_at, messages.id
      ), new_leads AS (
        SELECT period_contacts.* FROM period_contacts WHERE period_contacts.is_new_lead
      ), repeat_leads AS (
        SELECT period_contacts.* FROM period_contacts WHERE NOT period_contacts.is_new_lead
      )
    SQL

    PROVIDER_BOOKED_SQL = "NULLIF(sa.custom_attributes ->> 'medelement_reception_code', '') IS NOT NULL AND " \
                          "(sa.source = 'medelement' OR sa.custom_attributes ->> 'medelement_provider_sync_status' = 'succeeded')".freeze
    ATTENDED_SQL = "sa.status = 'completed'".freeze

    # Rescheduled: a cancelled appointment where the same contact has another completed/scheduled/confirmed appointment
    # within a ±7 days window of starts_at
    RESCHEDULED_SQL = <<~SQL.squish.freeze
      sa.status = 'cancelled' AND EXISTS (
        SELECT 1 FROM scheduling_appointments replacement
        WHERE replacement.account_id = sa.account_id
          AND replacement.contact_id = sa.contact_id
          AND replacement.id <> sa.id
          AND replacement.status IN ('completed', 'scheduled', 'confirmed')
          AND replacement.starts_at BETWEEN (sa.starts_at - INTERVAL '7 days') AND (sa.starts_at + INTERVAL '7 days')
      )
    SQL

    REMOVED_TIMESTAMP_SQL = <<~SQL.squish.freeze
      CASE
        WHEN NULLIF(sa.custom_attributes ->> 'medelement_removed_at', '') IS NOT NULL
             AND (sa.custom_attributes ->> 'medelement_removed_at') ~ '^\d{4}-\d{2}-\d{2}'
        THEN (sa.custom_attributes ->> 'medelement_removed_at')::timestamptz
        ELSE sa.updated_at
      END
    SQL

    EARLY_CANCELLED_SQL = <<~SQL.squish.freeze
      sa.status = 'cancelled' AND NOT (#{RESCHEDULED_SQL})
      AND (#{REMOVED_TIMESTAMP_SQL}) < (sa.starts_at - INTERVAL '1 hour')
    SQL

    TRUE_NO_SHOW_SQL = <<~SQL.squish.freeze
      sa.status = 'no_show' OR (
        sa.status = 'cancelled' AND NOT (#{RESCHEDULED_SQL})
        AND (#{REMOVED_TIMESTAMP_SQL}) >= (sa.starts_at - INTERVAL '1 hour')
      )
    SQL

    APPOINTMENT_PRICE_KZT_SQL = <<~SQL.squish.freeze
      CASE
        WHEN COALESCE(sa.service_amount, 0) > 0 THEN sa.service_amount::bigint
        ELSE COALESCE(ss.base_price, 0)::bigint
      END
    SQL

    QUERY_SQL = <<~SQL.squish.freeze
      #{COHORT_SQL}
      SELECT period_contacts.contact_id,
        period_contacts.is_new_lead,
        period_contacts.inbox_id,
        inboxes.name AS inbox_name,
        inboxes.channel_type,
        COALESCE(referral.source, referral.attribution_type, 'unknown') AS source,
        COALESCE(appointments.appointment_count, 0) AS appointment_count,
        COALESCE(appointments.booked_count, 0) AS booked_count,
        COALESCE(appointments.attended_count, 0) AS attended_count,
        COALESCE(appointments.cancelled_count, 0) AS cancelled_count,
        COALESCE(appointments.rescheduled_count, 0) AS rescheduled_count,
        COALESCE(appointments.early_cancelled_count, 0) AS early_cancelled_count,
        COALESCE(appointments.true_no_show_count, 0) AS true_no_show_count,
        COALESCE(appointments.unknown_attendance_count, 0) AS unknown_attendance_count,
        COALESCE(appointments.completed_revenue_kzt, 0) AS completed_revenue_kzt,
        COALESCE(appointments.rescheduled_saved_revenue_kzt, 0) AS rescheduled_saved_revenue_kzt,
        COALESCE(appointments.true_no_show_lost_revenue_kzt, 0) AS true_no_show_lost_revenue_kzt,
        COALESCE(deals.deal_count, 0) AS deal_count,
        COALESCE(deals.won_count, 0) AS won_count
      FROM period_contacts
      JOIN inboxes ON inboxes.id = period_contacts.inbox_id AND inboxes.account_id = $1
      LEFT JOIN LATERAL (
        SELECT source, attribution_type FROM meta_ad_referrals
        WHERE account_id = $1 AND message_id = period_contacts.message_id ORDER BY id LIMIT 1
      ) referral ON true
      LEFT JOIN LATERAL (
        SELECT COUNT(*) AS appointment_count,
          COUNT(*) FILTER (WHERE #{PROVIDER_BOOKED_SQL}) AS booked_count,
          COUNT(*) FILTER (WHERE #{ATTENDED_SQL}) AS attended_count,
          COUNT(*) FILTER (WHERE sa.status IN ('cancelled', 'no_show')) AS cancelled_count,
          COUNT(*) FILTER (WHERE #{RESCHEDULED_SQL}) AS rescheduled_count,
          COUNT(*) FILTER (WHERE #{EARLY_CANCELLED_SQL}) AS early_cancelled_count,
          COUNT(*) FILTER (WHERE #{TRUE_NO_SHOW_SQL}) AS true_no_show_count,
          COUNT(*) FILTER (WHERE sa.status = 'completed' AND NOT (#{ATTENDED_SQL})) AS unknown_attendance_count,
          COALESCE(SUM(#{APPOINTMENT_PRICE_KZT_SQL}) FILTER (WHERE #{ATTENDED_SQL}), 0) AS completed_revenue_kzt,
          COALESCE(SUM(#{APPOINTMENT_PRICE_KZT_SQL}) FILTER (WHERE #{RESCHEDULED_SQL}), 0) AS rescheduled_saved_revenue_kzt,
          COALESCE(SUM(#{APPOINTMENT_PRICE_KZT_SQL}) FILTER (WHERE #{TRUE_NO_SHOW_SQL}), 0) AS true_no_show_lost_revenue_kzt
        FROM scheduling_appointments sa
        LEFT JOIN scheduling_services ss ON ss.id = sa.service_id AND ss.account_id = sa.account_id
        WHERE sa.account_id = $1 AND sa.contact_id = period_contacts.contact_id
          AND sa.created_at >= period_contacts.first_inbound_at AND sa.created_at <= $4
      ) appointments ON true
      LEFT JOIN LATERAL (
        SELECT COUNT(DISTINCT crm_deals.id) AS deal_count,
          COUNT(DISTINCT crm_deals.id) FILTER (WHERE crm_stages.outcome = 'won') AS won_count
        FROM crm_deals JOIN crm_deal_contacts ON crm_deal_contacts.deal_id = crm_deals.id AND crm_deal_contacts.account_id = $1
        JOIN crm_stages ON crm_stages.id = crm_deals.stage_id
        WHERE crm_deals.account_id = $1 AND crm_deal_contacts.contact_id = period_contacts.contact_id AND crm_deal_contacts.primary
          AND crm_deals.created_at >= period_contacts.first_inbound_at AND crm_deals.created_at <= $4
      ) deals ON true
    SQL

    SCHEDULE_STATUS_FINANCE_SQL = <<~SQL.squish.freeze
      SELECT
        COUNT(*) AS total_schedule_appointments_count,
        COUNT(*) FILTER (WHERE #{ATTENDED_SQL}) AS completed_count,
        COUNT(*) FILTER (WHERE #{RESCHEDULED_SQL}) AS rescheduled_count,
        COUNT(*) FILTER (WHERE #{EARLY_CANCELLED_SQL}) AS early_cancelled_count,
        COUNT(*) FILTER (WHERE #{TRUE_NO_SHOW_SQL}) AS true_no_show_count,
        COALESCE(SUM(#{APPOINTMENT_PRICE_KZT_SQL}) FILTER (WHERE #{ATTENDED_SQL}), 0) AS completed_revenue_kzt,
        COALESCE(SUM(#{APPOINTMENT_PRICE_KZT_SQL}) FILTER (WHERE #{RESCHEDULED_SQL}), 0) AS rescheduled_saved_revenue_kzt,
        COALESCE(SUM(#{APPOINTMENT_PRICE_KZT_SQL}) FILTER (WHERE #{TRUE_NO_SHOW_SQL}), 0) AS true_no_show_lost_revenue_kzt
      FROM scheduling_appointments sa
      LEFT JOIN scheduling_services ss ON ss.id = sa.service_id AND ss.account_id = sa.account_id
      WHERE sa.account_id = $1
        AND sa.starts_at >= $2 AND sa.starts_at < $3
    SQL

    WHATSAPP_TOUCHES_SQL = <<~SQL.squish.freeze
      SELECT
        COUNT(*) FILTER (
          WHERE (
            r.template_params ->> 'name' LIKE 'booking_reminder_1d%'
            OR (r.relative_anchor = 'appointment.starts_at' AND r.relative_offset_seconds BETWEEN -100000 AND -43200)
          )
        ) AS reminder_1d_sent_count,
        COUNT(*) FILTER (
          WHERE (
            r.template_params ->> 'name' LIKE 'booking_reminder_1d%'
            OR (r.relative_anchor = 'appointment.starts_at' AND r.relative_offset_seconds BETWEEN -100000 AND -43200)
          )
          AND (
            sa.attendance_confirmed_at IS NOT NULL
            OR sa.status IN ('confirmed', 'completed')
            OR EXISTS (
              SELECT 1 FROM confirmation_requests cr
              WHERE cr.reminder_id = r.id AND cr.status = 'confirmed'
            )
          )
        ) AS reminder_1d_confirmed_count,
        COUNT(*) FILTER (
          WHERE (
            r.template_params ->> 'name' LIKE 'booking_reminder_2h%'
            OR (r.relative_anchor = 'appointment.starts_at' AND r.relative_offset_seconds BETWEEN -14400 AND -1800)
          )
        ) AS reminder_2h_sent_count,
        COUNT(*) FILTER (
          WHERE (
            r.template_params ->> 'name' LIKE 'booking_feedback_request%'
            OR r.relative_anchor = 'appointment.ends_at'
          )
        ) AS review_request_sent_count
      FROM reminders r
      LEFT JOIN scheduling_appointments sa
        ON sa.id = r.remindable_id AND r.remindable_type = 'Scheduling::Appointment' AND sa.account_id = r.account_id
      WHERE r.account_id = $1
        AND r.remindable_type = 'Scheduling::Appointment'
        AND r.status = 2
        AND COALESCE(r.completed_at, r.scheduled_at, r.created_at) >= $2
        AND COALESCE(r.completed_at, r.scheduled_at, r.created_at) < $3
    SQL

    private_constant :COHORT_SQL, :PROVIDER_BOOKED_SQL, :ATTENDED_SQL, :RESCHEDULED_SQL,
                     :REMOVED_TIMESTAMP_SQL, :EARLY_CANCELLED_SQL, :TRUE_NO_SHOW_SQL,
                     :APPOINTMENT_PRICE_KZT_SQL, :QUERY_SQL, :SCHEDULE_STATUS_FINANCE_SQL, :WHATSAPP_TOUCHES_SQL

    def initialize(account:, date_range:, now: Time.current)
      @account = account
      @date_range = date_range
      @now = now
    end

    def perform
      all_rows = ApplicationRecord.connection.select_all(QUERY_SQL, 'Lead appointments', query_binds).to_a
      new_rows = all_rows.select { |row| ActiveModel::Type::Boolean.new.cast(row['is_new_lead']) }
      repeat_rows = all_rows.reject { |row| ActiveModel::Type::Boolean.new.cast(row['is_new_lead']) }

      summary = metrics(new_rows)
      all_contacts_summary = metrics(all_rows)
      repeat_summary = metrics(repeat_rows)
      schedule_stats = schedule_status_and_finance
      touches = whatsapp_touches_summary

      active_slots = summary[:attended_appointments_count] + summary[:true_no_show_appointments_count]
      schedule_active_slots = schedule_stats[:completed_count] + schedule_stats[:true_no_show_count]

      summary.merge(
        booking_conversion_percent: percentage(summary[:booked_leads_count], summary[:leads_count]),
        attendance_conversion_percent: percentage(summary[:attended_leads_count], summary[:leads_count]),
        net_attendance_rate_percent: percentage(summary[:attended_appointments_count], active_slots),
        repeat_contacts_count: repeat_rows.length,
        all_contacts_funnel: {
          contacts_count: all_contacts_summary[:leads_count],
          booked_contacts_count: all_contacts_summary[:booked_leads_count],
          attended_contacts_count: all_contacts_summary[:attended_leads_count],
          booking_conversion_percent: percentage(all_contacts_summary[:booked_leads_count], all_contacts_summary[:leads_count]),
          attendance_conversion_percent: percentage(all_contacts_summary[:attended_leads_count], all_contacts_summary[:leads_count]),
          primary_contacts_count: summary[:leads_count],
          primary_booked_contacts_count: summary[:booked_leads_count],
          primary_attended_contacts_count: summary[:attended_leads_count],
          repeat_contacts_count: repeat_summary[:leads_count],
          repeat_booked_contacts_count: repeat_summary[:booked_leads_count],
          repeat_attended_contacts_count: repeat_summary[:attended_leads_count]
        },
        schedule_breakdown: schedule_stats.merge(
          net_attendance_rate_percent: percentage(schedule_stats[:completed_count], schedule_active_slots)
        ),
        whatsapp_touches: touches,
        appointments_without_contact_count: account.scheduling_appointments.where(contact_id: nil, created_at: date_range.from_at...date_range.until_at).count,
        attribution_breakdown: new_rows.group_by { |row| row.values_at('inbox_id', 'inbox_name', 'channel_type', 'source') }
                                       .map { |(inbox_id, inbox_name, channel_type, source), leads| metrics(leads).merge(inbox_id: inbox_id, inbox_name: inbox_name, channel_type: channel_type, source: source) }
                                       .sort_by { |row| -row[:leads_count] }.first(MAX_BREAKDOWN_ROWS),
        observed_at: now.iso8601,
        cohort: 'first_inbound_communication_contact',
        outcomes: 'observed_to_now',
        scheduling_enabled: account.feature_enabled?('scheduling')
      )
    end

    private

    attr_reader :account, :date_range, :now

    def cohort_binds
      [
        bind('account_id', account.id, Account.type_for_attribute('id')),
        bind('from_at', date_range.from_at, Message.type_for_attribute('created_at')),
        bind('until_at', date_range.until_at, Message.type_for_attribute('created_at'))
      ]
    end

    def query_binds
      cohort_binds + [bind('observed_at', now, Message.type_for_attribute('created_at'))]
    end

    def bind(name, value, type)
      ActiveRecord::Relation::QueryAttribute.new(name, value, type)
    end

    def schedule_status_and_finance
      row = ApplicationRecord.connection.select_one(SCHEDULE_STATUS_FINANCE_SQL, 'Schedule status and finance', cohort_binds) || {}
      {
        total_appointments_count: row['total_schedule_appointments_count'].to_i,
        completed_count: row['completed_count'].to_i,
        rescheduled_count: row['rescheduled_count'].to_i,
        early_cancelled_count: row['early_cancelled_count'].to_i,
        true_no_show_count: row['true_no_show_count'].to_i,
        completed_revenue_kzt: row['completed_revenue_kzt'].to_i,
        rescheduled_saved_revenue_kzt: row['rescheduled_saved_revenue_kzt'].to_i,
        true_no_show_lost_revenue_kzt: row['true_no_show_lost_revenue_kzt'].to_i
      }
    end

    def whatsapp_touches_summary
      row = ApplicationRecord.connection.select_one(WHATSAPP_TOUCHES_SQL, 'WhatsApp schedule touches', cohort_binds) || {}
      sent_1d = row['reminder_1d_sent_count'].to_i
      confirmed_1d = row['reminder_1d_confirmed_count'].to_i
      sent_2h = row['reminder_2h_sent_count'].to_i
      sent_review = row['review_request_sent_count'].to_i
      {
        total_sent_count: sent_1d + sent_2h + sent_review,
        reminder_1d_sent_count: sent_1d,
        reminder_1d_confirmed_count: confirmed_1d,
        reminder_1d_confirmation_rate_percent: percentage(confirmed_1d, sent_1d),
        reminder_2h_sent_count: sent_2h,
        review_request_sent_count: sent_review
      }
    end

    def metrics(rows)
      {
        leads_count: rows.length,
        booked_leads_count: rows.count { |row| row['booked_count'].to_i.positive? },
        attended_leads_count: rows.count { |row| row['attended_count'].to_i.positive? },
        appointments_count: rows.sum { |row| row['appointment_count'].to_i },
        provider_booked_appointments_count: rows.sum { |row| row['booked_count'].to_i },
        attended_appointments_count: rows.sum { |row| row['attended_count'].to_i },
        rescheduled_appointments_count: rows.sum { |row| row['rescheduled_count'].to_i },
        early_cancelled_appointments_count: rows.sum { |row| row['early_cancelled_count'].to_i },
        true_no_show_appointments_count: rows.sum { |row| row['true_no_show_count'].to_i },
        cancelled_or_no_show_appointments_count: rows.sum { |row| row['cancelled_count'].to_i },
        unknown_attendance_appointments_count: rows.sum { |row| row['unknown_attendance_count'].to_i },
        completed_revenue_kzt: rows.sum { |row| row['completed_revenue_kzt'].to_i },
        rescheduled_saved_revenue_kzt: rows.sum { |row| row['rescheduled_saved_revenue_kzt'].to_i },
        true_no_show_lost_revenue_kzt: rows.sum { |row| row['true_no_show_lost_revenue_kzt'].to_i },
        deals_count: rows.sum { |row| row['deal_count'].to_i },
        won_deals_count: rows.sum { |row| row['won_count'].to_i }
      }
    end

    def percentage(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator * 100).round(1)
    end
  end
end
