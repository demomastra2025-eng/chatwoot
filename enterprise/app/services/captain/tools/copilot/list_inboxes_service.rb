# frozen_string_literal: true

class Captain::Tools::Copilot::ListInboxesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_inboxes'
  end

  description 'List account inboxes with safe channel, assignment, working-hours, and Captain auto-reply metadata for account administrators'
  param :query, type: :string, desc: 'Optional partial match against inbox name or business name', required: false
  param :channel_type,
        type: :string,
        desc: 'Optional channel type filter, for example Channel::WhatsappWeb or Channel::Email',
        required: false
  param :captain_enabled,
        type: :boolean,
        desc: 'Optional filter for inboxes connected to a Captain assistant',
        required: false
  param :include_members, type: :boolean, desc: 'Whether to include inbox member IDs and names. Defaults to false', required: false
  param :limit, type: :number, desc: 'Maximum number of inboxes to return', required: false

  def execute(query: nil, channel_type: nil, captain_enabled: nil, include_members: false, limit: nil)
    ensure_account_administrator!

    include_member_payloads = cast_boolean(include_members, default: false)
    inboxes = filtered_inboxes(query: query, channel_type: channel_type)
    inboxes = filter_by_captain_enabled(inboxes, captain_enabled) unless captain_enabled.nil?

    formatted_payload(
      filters: {
        query: query,
        channel_type: channel_type,
        captain_enabled: captain_enabled,
        include_members: include_member_payloads
      }.compact,
      total_count: inboxes.count,
      inboxes: inbox_records(inboxes, include_members: include_member_payloads, limit: limit),
      auto_reply_modes: CaptainInbox::AUTO_REPLY_MODES
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def filtered_inboxes(query:, channel_type:)
    scope = account.inboxes.active
                   .includes(:assignment_policy, captain_inbox: :captain_assistant)
                   .order(:name, :id)
    if query.present?
      scope = scope.where('LOWER(inboxes.name) ILIKE :query OR LOWER(inboxes.business_name) ILIKE :query',
                          query: "%#{query.to_s.downcase}%")
    end
    scope = scope.where(channel_type: channel_type) if channel_type.present?
    scope
  end

  def filter_by_captain_enabled(scope, value)
    enabled = cast_boolean(value)
    joined_scope = scope.left_outer_joins(:captain_inbox)
    return joined_scope.where.not(captain_inboxes: { id: nil }) if enabled

    joined_scope.where(captain_inboxes: { id: nil })
  end

  def inbox_records(inboxes, include_members:, limit:)
    records_scope = inboxes.limit(parse_limit(limit))
    records_scope = records_scope.includes(:members) if include_members
    records_scope.map { |inbox| inbox_payload(inbox, include_members: include_members) }
  end

  def inbox_payload(inbox, include_members:)
    assignment_policy = inbox.assignment_policy
    assignment_policy = nil unless assignment_policy&.account_id == account.id

    payload = {
      id: inbox.id,
      name: inbox.name,
      business_name: inbox.business_name,
      channel_type: inbox.display_channel_type,
      raw_channel_type: inbox.channel_type,
      timezone: inbox.timezone,
      enable_auto_assignment: inbox.enable_auto_assignment,
      working_hours_enabled: inbox.working_hours_enabled,
      assignment_policy: assignment_policy_payload(assignment_policy),
      captain: captain_inbox_payload(inbox.captain_inbox),
      created_at: inbox.created_at&.iso8601,
      updated_at: inbox.updated_at&.iso8601
    }

    payload[:members] = member_payloads(inbox) if include_members
    payload.compact
  end

  def assignment_policy_payload(policy)
    return nil if policy.blank?

    {
      id: policy.id,
      name: policy.name,
      enabled: policy.enabled,
      assignment_order: policy.assignment_order
    }
  end

  def captain_inbox_payload(captain_inbox)
    return { enabled: false, available_auto_reply_modes: CaptainInbox::AUTO_REPLY_MODES } if captain_inbox.blank?

    {
      enabled: true,
      assistant_id: captain_inbox.captain_assistant_id,
      assistant_name: captain_inbox.captain_assistant&.name,
      auto_reply_mode: captain_inbox.auto_reply_mode,
      auto_reply_allowed_now: captain_inbox.auto_reply_allowed_now?,
      available_auto_reply_modes: CaptainInbox::AUTO_REPLY_MODES
    }.compact
  end

  def member_payloads(inbox)
    inbox.members.map do |member|
      {
        id: member.id,
        name: member.name,
        email: member.email
      }
    end
  end
end
