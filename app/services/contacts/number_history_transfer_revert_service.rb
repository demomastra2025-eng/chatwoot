# Manual reverse of a recorded number transfer (rake onelink:shared_phones:revert_transfer). Moves back only the recorded
# ContactInboxes that still belong to the recipient, their conversations and the contact messages authored by the
# recipient in them, the rows tied to those chats (Contacts::NumberHistoryTransferRevertRows), the recorded touches that
# followed the chats, telephony endpoints and the LID identifier, refreshes the threads, posts an activity message and
# records the revert on both contacts. Amendments of the transfer (a WhatsApp Web LID chat proven tied later) are
# reverted with it. The recipient keeps the number as primary unless restore_primary: then it becomes the recipient's
# доп. номер again (shared from the previous holder), and the previous holder gets it back as primary when its own
# primary is blank. The dry run (default) only counts; applying it moves chats and therefore needs
# ONELINK_SHARED_PHONE_HISTORY_TRANSFER (Contacts::SharedPhoneSwitches), like every other history move.
class Contacts::NumberHistoryTransferRevertService
  Result = Data.define(:entry, :moved_contact_inboxes, :moved_conversations, :moved_messages, :dry_run)
  Error = Contacts::NumberHistoryTransferService::Error
  TRANSFERS_KEY = Contacts::SharedPhone::TRANSFERS_KEY

  def initialize(contact:, transfer_id:, actor: nil, restore_primary: false, dry_run: true)
    @to = contact
    @transfer_id = transfer_id.to_s
    @actor = actor
    @restore_primary = restore_primary
    @dry_run = dry_run
  end

  def perform
    entry, from = validated_transfer
    return preview(entry, [entry] + amendments(entry)) if @dry_run

    transfer = Contacts::NumberHistoryTransferService
    raise transfer::Disabled, 'Number history transfer is switched off' unless transfer.enabled?

    ActiveRecord::Base.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: @to.account_id)
      Contact.where(id: [from.id, @to.id]).order(:id).lock('FOR NO KEY UPDATE').to_a
      entry, from = validated_transfer # re-read under the locks: the log may have gained an amendment meanwhile
      revert!(entry, [entry] + amendments(entry), from)
    end
  end

  private

  def validated_transfer
    @to.reload
    entry = Contacts::NumberHistoryTransferService.find_entry(@to, @transfer_id)
    raise Error, 'Transfer not found on this contact' if entry.blank?
    raise Error, 'Transfer already reverted' if entry['reverted_at'].present?

    from = Contact.find_by(id: entry['counterpart_contact_id'], account_id: @to.account_id)
    raise Error, 'Previous holder no longer exists' if from.blank?

    counterpart = Contacts::NumberHistoryTransferService.find_entry(from, @transfer_id, direction: 'out')
    raise Error, 'Previous holder has no matching log entry' if counterpart.blank?

    [entry, from]
  end

  # Amendments recorded later for the same previous holder (amendment_of = this transfer) go back with it.
  def amendments(entry)
    Array(@to.custom_attributes.to_h[TRANSFERS_KEY]).select do |item|
      item['direction'] == 'in' && item['amendment_of'] == entry['id'] && item['reverted_at'].blank? &&
        item['counterpart_contact_id'] == entry['counterpart_contact_id']
    end
  end

  def recorded_ids(entries, key) = entries.flat_map { |item| Array(item[key]) }.map(&:to_i).uniq

  def recorded_contact_inbox_ids(entries)
    ContactInbox.where(id: recorded_ids(entries, 'contact_inbox_ids'), contact_id: @to.id).order(:id).pluck(:id)
  end

  def preview(entry, entries)
    ci_ids = recorded_contact_inbox_ids(entries)
    conversation_ids = Conversation.where(contact_inbox_id: ci_ids).pluck(:id)
    messages = Message.where(conversation_id: conversation_ids, sender_type: 'Contact', sender_id: @to.id).count
    result(entry, { 'contact_inbox_ids' => ci_ids, 'conversation_ids' => conversation_ids, 'moved_message_count' => messages }, dry_run: true)
  end

  def revert!(entry, entries, from)
    now = Time.current
    ci_ids = ContactInbox.where(id: recorded_contact_inbox_ids(entries)).order(:id).lock('FOR NO KEY UPDATE').pluck(:id)
    conversation_ids = Conversation.where(contact_inbox_id: ci_ids).order(:id).lock('FOR NO KEY UPDATE').pluck(:id)
    messages = move_back!(entries, from, ci_ids, conversation_ids, now)
    rows = Contacts::NumberHistoryTransferRevertRows.new(from: from, to: @to, contact_inbox_ids: ci_ids, conversation_ids: conversation_ids).perform
    Conversation.where(id: conversation_ids).find_each(&:refresh_communication_thread!)
    Contacts::NumberHistoryTransferRevertRows.refresh_referral_threads!(conversation_ids)
    restore_primary!(entry, from) if @restore_primary
    moved = { 'contact_inbox_ids' => ci_ids, 'conversation_ids' => conversation_ids, 'moved_message_count' => messages, 'conversation_rows' => rows }
    record_revert!(entry, entries, from, moved, now)
    result(entry, moved, dry_run: false)
  end

  def result(entry, moved, dry_run:)
    Result.new(entry: entry, moved_contact_inboxes: moved['contact_inbox_ids'].size, moved_conversations: moved['conversation_ids'].size,
               moved_messages: moved['moved_message_count'], dry_run: dry_run)
  end

  # rubocop:disable Rails/SkipsModelValidations
  def move_back!(entries, from, ci_ids, conversation_ids, now)
    ContactInbox.where(id: ci_ids).update_all(contact_id: from.id, updated_at: now)
    ContactChannelProfile.where(contact_inbox_id: ci_ids).update_all(contact_id: from.id, updated_at: now)
    Conversation.where(id: conversation_ids).update_all(contact_id: from.id, updated_at: now)
    touch_ids = recorded_ids(entries, 'settled_reminder_ids') | recorded_ids(entries, 'followed_open_reminder_ids')
    Reminder.where(id: touch_ids, target_contact_id: @to.id).update_all(target_contact_id: from.id) if touch_ids.any?
    revert_endpoints!(entries, from)
    entries.each { |item| revert_identifier!(item, from) }
    Message.where(conversation_id: conversation_ids, sender_type: 'Contact', sender_id: @to.id).update_all(sender_id: from.id, updated_at: now)
  end

  def revert_endpoints!(entries, from)
    ids = recorded_ids(entries, 'telephony_endpoint_ids')
    return if ids.empty? || !ActiveRecord::Base.connection.data_source_exists?('telephony_contact_endpoints')

    ActiveRecord::Base.connection.update(
      ActiveRecord::Base.sanitize_sql_array(
        ['UPDATE telephony_contact_endpoints SET contact_id = ? WHERE contact_id = ? AND id IN (?)', from.id, @to.id, ids]
      )
    )
  end

  def revert_identifier!(entry, from)
    identifier = entry.dig('moved_identifier', 'value')
    return if identifier.blank?

    @to.update_columns(identifier: nil) if @to.identifier == identifier
    from.update_columns(identifier: identifier) if from.identifier.blank?
  end
  # rubocop:enable Rails/SkipsModelValidations

  def restore_primary!(entry, from)
    phone = entry['phone']
    return unless @to.phone_number == phone

    attributes = @to.custom_attributes.to_h
    Contacts::SharedPhone.record_share!(attributes, phone: phone, owner_id: from.id, via: Contacts::SharedPhone::VIA_OWNER_PRIMARY)
    @to.update!(phone_number: nil, custom_attributes: attributes)
    from.update!(phone_number: phone) if from.phone_number.blank?
  end

  def record_revert!(entry, entries, from, moved, now)
    actor = @actor.is_a?(User) ? { 'type' => 'User', 'id' => @actor.id } : { 'type' => 'system', 'id' => nil }
    service = Contacts::NumberHistoryTransferService
    reverted_ids = entries.pluck('id')
    [@to, from].each do |contact|
      reverted_ids.each { |id| service.update_log!(contact, id) { |item| item.merge('reverted_at' => now.iso8601, 'reverted_by' => actor) } }
    end
    revert_entry = moved.merge('id' => SecureRandom.uuid, 'revert_of' => entry['id'], 'reverted_amendment_ids' => reverted_ids - [entry['id']],
                               'phone' => entry['phone'], 'basis' => 'revert', 'actor' => actor, 'at' => now.iso8601,
                               'restore_primary' => @restore_primary)
    service.append_log!(from, revert_entry.merge('direction' => 'in', 'counterpart_contact_id' => @to.id))
    service.append_log!(@to, revert_entry.merge('direction' => 'out', 'counterpart_contact_id' => from.id))
    post_revert_activity!(entry, from, moved['conversation_ids'], now)
  end

  def post_revert_activity!(entry, from, conversation_ids, now)
    content = Contacts::NumberHistoryTransferService.activity_content(account: @to.account, key: 'reverted', phone: entry['phone'],
                                                                      parties: [@to, from], actor: @actor, at: now)
    Conversation.where(id: conversation_ids).find_each do |conversation|
      conversation.messages.create!(account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity, content: content)
    end
  end
end
