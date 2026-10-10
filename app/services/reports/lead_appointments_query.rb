module Reports
  class LeadAppointmentsQuery
    MAX_BREAKDOWN_ROWS = 20
    COHORT_SQL = <<~SQL.squish.freeze
      WITH period_contacts AS (
        SELECT DISTINCT ON (conversations.contact_id)
          conversations.contact_id, messages.created_at AS first_inbound_at, messages.id AS message_id, messages.inbox_id
        FROM messages JOIN conversations ON conversations.id = messages.conversation_id AND conversations.account_id = $1
        WHERE messages.account_id = $1 AND messages.message_type = 0 AND NOT messages.private
          AND messages.created_at >= $2 AND messages.created_at < $3
        ORDER BY conversations.contact_id, messages.created_at, messages.id
      ), new_leads AS (
        SELECT period_contacts.* FROM period_contacts
        WHERE NOT EXISTS (
          SELECT 1 FROM conversations previous_conversation
          JOIN messages previous_message ON previous_message.conversation_id = previous_conversation.id
          WHERE previous_conversation.account_id = $1 AND previous_conversation.contact_id = period_contacts.contact_id
            AND previous_message.account_id = $1 AND previous_message.message_type = 0 AND NOT previous_message.private
            AND (previous_message.created_at, previous_message.id) < (period_contacts.first_inbound_at, period_contacts.message_id)
        )
      )
    SQL
    PROVIDER_BOOKED_SQL = "NULLIF(custom_attributes ->> 'medelement_reception_code', '') IS NOT NULL AND " \
                          "(source = 'medelement' OR custom_attributes ->> 'medelement_provider_sync_status' = 'succeeded')".freeze
    ATTENDED_SQL = "status = 'completed' AND (attendance_confirmed_at IS NOT NULL OR " \
                   "COALESCE(custom_attributes -> 'provider_status_audit' ->> 'reason', '') = 'provider_explicit_completed')".freeze

    QUERY_SQL = <<~SQL.squish.freeze
      #{COHORT_SQL}
      SELECT new_leads.contact_id, new_leads.inbox_id, inboxes.name AS inbox_name, inboxes.channel_type,
        COALESCE(referral.source, referral.attribution_type, 'unknown') AS source,
        COALESCE(appointments.appointment_count, 0) AS appointment_count,
        COALESCE(appointments.booked_count, 0) AS booked_count,
        COALESCE(appointments.attended_count, 0) AS attended_count,
        COALESCE(appointments.cancelled_count, 0) AS cancelled_count,
        COALESCE(appointments.unknown_attendance_count, 0) AS unknown_attendance_count,
        COALESCE(deals.deal_count, 0) AS deal_count, COALESCE(deals.won_count, 0) AS won_count
      FROM new_leads JOIN inboxes ON inboxes.id = new_leads.inbox_id AND inboxes.account_id = $1
      LEFT JOIN LATERAL (
        SELECT source, attribution_type FROM meta_ad_referrals
        WHERE account_id = $1 AND message_id = new_leads.message_id ORDER BY id LIMIT 1
      ) referral ON true
      LEFT JOIN LATERAL (
        SELECT COUNT(*) AS appointment_count,
          COUNT(*) FILTER (WHERE #{PROVIDER_BOOKED_SQL}) AS booked_count,
          COUNT(*) FILTER (WHERE #{ATTENDED_SQL}) AS attended_count,
          COUNT(*) FILTER (WHERE status IN ('cancelled', 'no_show')) AS cancelled_count,
          COUNT(*) FILTER (WHERE status = 'completed' AND NOT (#{ATTENDED_SQL})) AS unknown_attendance_count
        FROM scheduling_appointments
        WHERE account_id = $1 AND contact_id = new_leads.contact_id
          AND created_at >= new_leads.first_inbound_at AND created_at <= $4
      ) appointments ON true
      LEFT JOIN LATERAL (
        SELECT COUNT(DISTINCT crm_deals.id) AS deal_count,
          COUNT(DISTINCT crm_deals.id) FILTER (WHERE crm_stages.outcome = 'won') AS won_count
        FROM crm_deals JOIN crm_deal_contacts ON crm_deal_contacts.deal_id = crm_deals.id AND crm_deal_contacts.account_id = $1
        JOIN crm_stages ON crm_stages.id = crm_deals.stage_id
        WHERE crm_deals.account_id = $1 AND crm_deal_contacts.contact_id = new_leads.contact_id AND crm_deal_contacts.primary
          AND crm_deals.created_at >= new_leads.first_inbound_at AND crm_deals.created_at <= $4
      ) deals ON true
    SQL
    REPEAT_CONTACTS_SQL = "#{COHORT_SQL} SELECT (SELECT COUNT(*) FROM period_contacts) - (SELECT COUNT(*) FROM new_leads)".freeze
    private_constant :COHORT_SQL, :PROVIDER_BOOKED_SQL, :ATTENDED_SQL, :QUERY_SQL, :REPEAT_CONTACTS_SQL

    def initialize(account:, date_range:, now: Time.current)
      @account = account
      @date_range = date_range
      @now = now
    end

    def perform
      rows = ApplicationRecord.connection.select_all(QUERY_SQL, 'Lead appointments', query_binds).to_a
      summary = metrics(rows)
      summary.merge(
        booking_conversion_percent: percentage(summary[:booked_leads_count], summary[:leads_count]),
        attendance_conversion_percent: percentage(summary[:attended_leads_count], summary[:leads_count]),
        repeat_contacts_count: repeat_contacts_count,
        appointments_without_contact_count: account.scheduling_appointments.where(contact_id: nil, created_at: date_range.from_at...date_range.until_at).count,
        attribution_breakdown: rows.group_by { |row| row.values_at('inbox_id', 'inbox_name', 'channel_type', 'source') }
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

    def repeat_contacts_count
      ApplicationRecord.connection.select_value(REPEAT_CONTACTS_SQL, 'Repeat lead contacts', cohort_binds).to_i
    end

    def metrics(rows)
      {
        leads_count: rows.length,
        booked_leads_count: rows.count { |row| row['booked_count'].to_i.positive? },
        attended_leads_count: rows.count { |row| row['attended_count'].to_i.positive? },
        appointments_count: rows.sum { |row| row['appointment_count'].to_i },
        provider_booked_appointments_count: rows.sum { |row| row['booked_count'].to_i },
        attended_appointments_count: rows.sum { |row| row['attended_count'].to_i },
        cancelled_or_no_show_appointments_count: rows.sum { |row| row['cancelled_count'].to_i },
        unknown_attendance_appointments_count: rows.sum { |row| row['unknown_attendance_count'].to_i },
        deals_count: rows.sum { |row| row['deal_count'].to_i },
        won_deals_count: rows.sum { |row| row['won_count'].to_i }
      }
    end

    def percentage(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator * 100).round(1)
    end
  end
end
