# frozen_string_literal: true

# The channels the operator has to authorize again: WhatsApp, Facebook, Instagram, TikTok and Email keep that mark
# (Reauthorizable). The mark lives in Redis, so the ids of the channels are read first and the marks with one MGET per
# kind of channel; WhatsApp keeps the mark in its settings as well (Whatsapp::DurableReauthorization), so a Redis that lost
# it does not make the channel look healthy. Telegram and the rest have no such state.
class SuperAdmin::DashboardAlerts::Channels < SuperAdmin::DashboardAlerts::Check
  BATCH = 1000
  # The channels that can ask to be authorized again, by class, and the name the alert shows
  KINDS = {
    'Channel::Whatsapp' => 'WhatsApp', 'Channel::FacebookPage' => 'Facebook', 'Channel::Instagram' => 'Instagram',
    'Channel::Tiktok' => 'TikTok', 'Channel::Email' => 'Email'
  }.freeze

  def alerts
    flagged = KINDS.flat_map { |class_name, kind| flagged_channels(class_name.constantize).map { |row| row.merge(kind: kind) } }
    return [] if flagged.empty?

    [alert(:reauthorization, severity: :danger, items: items(flagged), count: flagged.size)]
  end

  private

  # [{ id:, account_id:, class: }] of the channels of one class that need authorizing again
  def flagged_channels(klass)
    rows = klass.pluck(:id, :account_id)
    marked = rows.each_slice(BATCH).flat_map do |slice|
      values = ::Redis::Alfred.mget(slice.map { |id, _account_id| Reauthorizable.required_key(klass, id) })
      slice.zip(values).select { |_row, value| value.present? }.map { |(id, _account_id), _value| id }
    end
    ids = (marked + durable_ids(klass)).to_set
    rows.filter_map { |id, account_id| { id: id, account_id: account_id, class: klass.name } if ids.include?(id) }
  end

  def durable_ids(klass)
    return [] unless klass.name == 'Channel::Whatsapp'

    klass.where("LOWER(provider_config->>'reauthorization_required') IN ('true', 't', '1', 'on')").pluck(:id)
  end

  # The first channels, by account, with the name of the inbox and of the account (two queries for all of them)
  def items(flagged)
    shown = flagged.sort_by { |row| [row[:account_id], row[:class], row[:id]] }.first(SuperAdmin::DashboardAlerts::LIST_LIMIT)
    accounts = Account.where(id: shown.pluck(:account_id)).pluck(:id, :name).to_h
    inboxes = inbox_names(shown)
    shown.map do |row|
      name = [inboxes[[row[:class], row[:id]]], accounts[row[:account_id]] || "##{row[:account_id]}"].compact_blank.join(' · ')
      { label: name, url: routes.super_admin_account_path(row[:account_id]), note: row[:kind] }
    end
  end

  def inbox_names(shown)
    Inbox.where(channel_type: shown.pluck(:class).uniq, channel_id: shown.pluck(:id)).pluck(:channel_type, :channel_id, :name)
         .to_h { |type, id, name| [[type, id], name] }
  end
end
