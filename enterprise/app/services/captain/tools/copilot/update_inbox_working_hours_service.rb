# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateInboxWorkingHoursService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_inbox_working_hours'
  end

  description 'Update workspace weekly working hours using a JSON array of day schedules'
  param :inbox_id, type: :number, desc: 'Account inbox ID', required: true
  param :working_hours_json,
        type: :string,
        desc: 'JSON array with day_of_week, closed_all_day/open_all_day, open_hour/open_minutes, close_hour/close_minutes',
        required: true
  param :working_hours_enabled, type: :boolean, desc: 'Legacy parameter; the workspace schedule is always enabled when configured', required: false

  def execute(inbox_id:, working_hours_json:, **_legacy_options)
    ensure_account_administrator!

    inbox = account.inboxes.active.find(inbox_id)
    entries = parse_working_hours!(working_hours_json)

    account.update!(workspace_working_hours: entries)

    formatted_payload(
      action: 'update_inbox_working_hours',
      inbox: {
        id: inbox.id,
        name: inbox.name,
        timezone: account.workspace_working_hours_timezone,
        working_hours_enabled: account.workspace_working_hours_configured?
      },
      working_hours: account.workspace_working_hours_schedule
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def parse_working_hours!(value)
    parsed = JSON.parse(value.to_s)
    raise ArgumentError, 'working_hours_json must be a JSON array' unless parsed.is_a?(Array)

    parsed.map do |entry|
      hash = entry.to_h.stringify_keys.slice(*Inbox::OFFISABLE_ATTRS)
      day = Integer(hash.fetch('day_of_week'))
      raise ArgumentError, 'day_of_week must be between 0 and 6' unless day.between?(0, 6)

      hash.merge('day_of_week' => day)
    rescue KeyError, ArgumentError, TypeError
      raise ArgumentError, 'Each working hour entry must include integer day_of_week between 0 and 6'
    end
  rescue JSON::ParserError
    raise ArgumentError, 'working_hours_json must be valid JSON'
  end
end
