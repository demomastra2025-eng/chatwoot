# frozen_string_literal: true

class Captain::Tools::Copilot::ListInboxesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_inboxes'
  end

  description 'List account inboxes with routing, assignment, and Captain auto-reply metadata for account administrators'
  param :query, type: :string, desc: 'Optional partial match against inbox name', required: false
  param :channel_type,
        type: :string,
        desc: 'Optional exact channel type filter, for example Channel::Whatsapp or Channel::TelegramPersonal',
        required: false
  param :captain_enabled,
        type: :boolean,
        desc: 'Optional filter for inboxes connected to a Captain assistant',
        required: false
  param :limit, type: :number, desc: 'Maximum number of inboxes to return', required: false

  def execute(query: nil, channel_type: nil, captain_enabled: nil, limit: nil)
    ensure_account_administrator!

    inboxes = account.inboxes.active.includes(:assignment_policy, captain_inbox: :captain_assistant).order(:name, :id)
    inboxes = inboxes.where('LOWER(inboxes.name) ILIKE :query', query: "%#{query.to_s.downcase}%") if query.present?
    inboxes = inboxes.where(channel_type: channel_type) if channel_type.present?
    inboxes = filter_by_captain_enabled(inboxes, captain_enabled) unless captain_enabled.nil?

    total_count = inboxes.count
    records = inboxes.limit(parse_limit(limit)).map { |inbox| inbox_payload(inbox) }

    formatted_payload(
      filters: {
        query: query,
        channel_type: channel_type,
        captain_enabled: captain_enabled
      }.compact,
      total_count: total_count,
      inboxes: records
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def filter_by_captain_enabled(scope, value)
    enabled = cast_boolean(value)
    joined_scope = scope.left_outer_joins(:captain_inbox)
    return joined_scope.where.not(captain_inboxes: { id: nil }) if enabled

    joined_scope.where(captain_inboxes: { id: nil })
  end

  def inbox_payload(inbox)
    captain_inbox = inbox.captain_inbox
    assignment_policy = inbox.assignment_policy
    assignment_policy = nil unless assignment_policy&.account_id == account.id

    {
      id: inbox.id,
      name: inbox.name,
      channel_type: inbox.channel_type,
      timezone: inbox.timezone,
      enable_auto_assignment: inbox.enable_auto_assignment,
      working_hours_enabled: inbox.working_hours_enabled,
      assignment_policy: assignment_policy_payload(assignment_policy),
      captain: captain_payload(captain_inbox),
      created_at: inbox.created_at&.iso8601,
      updated_at: inbox.updated_at&.iso8601
    }.compact
  end

  def assignment_policy_payload(assignment_policy)
    return nil if assignment_policy.blank?

    {
      id: assignment_policy.id,
      name: assignment_policy.name,
      enabled: assignment_policy.enabled
    }
  end

  def captain_payload(captain_inbox)
    assistant = captain_inbox&.captain_assistant

    {
      enabled: captain_inbox.present?,
      assistant_id: assistant&.id,
      assistant_name: assistant&.name,
      auto_reply_mode: captain_inbox&.auto_reply_mode,
      auto_reply_allowed_now: captain_inbox&.auto_reply_allowed_now?,
      available_auto_reply_modes: CaptainInbox::AUTO_REPLY_MODES
    }.compact
  end
end
