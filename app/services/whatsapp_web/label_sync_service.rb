class WhatsappWeb::LabelSyncService
  LABEL_PREFIX = 'wa'.freeze

  pattr_initialize [:channel!]

  def sync_label_definition(payload)
    payload = payload.to_h.deep_stringify_keys
    label_id = payload['id'].to_s
    return if label_id.blank?

    next_map = channel.label_map.deep_dup
    if ActiveModel::Type::Boolean.new.cast(payload['deleted'])
      next_map.delete(label_id)
      channel.update_label_map!(next_map)
      return
    end

    title = normalized_title(payload['name'], label_id)
    label = channel.account.labels.find_or_initialize_by(title: title)
    label.color = normalize_color(payload['color'])
    label.save! if label.new_record? || label.changed?

    next_map[label_id] = {
      'title' => label.title,
      'name' => payload['name'],
      'color' => label.color
    }

    channel.update_label_map!(next_map)
  end

  def sync_label_association(payload)
    payload = payload.to_h.deep_stringify_keys
    return if ignored_chat?(payload['chatId'])

    label_title = channel.label_map.dig(payload['labelId'].to_s, 'title')
    return if label_title.blank?

    conversation = find_conversation(payload['chatId'].to_s)
    return if conversation.blank?

    if payload['type'] == 'remove'
      conversation.update!(label_list: conversation.label_list - [label_title])
    else
      conversation.add_labels([label_title]) unless conversation.label_list.include?(label_title)
    end
  end

  private

  def normalized_title(name, label_id)
    slug = name.to_s.parameterize(separator: '_')
    slug = "label_#{label_id}" if slug.blank?
    "#{LABEL_PREFIX}_#{slug}".first(100)
  end

  def normalize_color(color)
    value = color.to_s
    return '#1f93ff' if value.blank?
    return value if value.start_with?('#')

    "##{value}"
  end

  def find_conversation(remote_jid)
    source_id = remote_jid.split('@').first

    channel.inbox.conversations.joins(:contact_inbox).where(contact_inboxes: { source_id: [source_id, remote_jid] }).last
  end

  def ignored_chat?(remote_jid)
    channel.ignored_remote_jid?(remote_jid.to_s) || remote_jid.to_s.end_with?('@g.us')
  end
end
