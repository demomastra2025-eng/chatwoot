require 'digest'

# M6: moves the chat history of one phone number from its previous holder to the card that now holds it as primary.
#
# Only the explicit promotion (Contacts::SharedPhonePromotionService: MedElement sync or the administrator button) and
# the manual revert call this; no automatic merge ever rewrites history. What moves: the ContactInboxes whose source is
# that number (Contacts::SharedPhone.identifying_contact_inboxes, owned by `from`), their channel profiles and
# conversations, the contact messages of `from` in those conversations, and rows tied to those conversations (calls,
# call sessions, CSAT answers, ad referrals, lead submissions), plus telephony endpoints of the number. Everything else
# (other channels, email, notes, deals, appointments) stays with `from`.
#
# Each moved conversation gets an activity message; both contacts record the transfer (ids, timestamp, actor, basis) in
# custom_attributes['medelement_number_transfers'] so it can be traced and reverted (Contacts::NumberHistoryTransfer
# RevertService). Locks: phone identity lock -> contacts (id order) -> ContactInboxes -> touches of the previous holder
# -> conversations (FOR NO KEY UPDATE, message inserts are not blocked). Touches come before conversations as in a touch
# execution (touch row, then the conversation it delivers into): an in-flight delivery finishes first and its touch then
# follows the chat, or the delivery re-reads the moved chat and re-queues. In-flight inbound traffic is fixed by
# Contacts::NumberHistoryTransferSweepJob.
#
# Switched off by default (ONELINK_SHARED_PHONE_HISTORY_TRANSFER, Contacts::SharedPhoneSwitches): perform! raises
# Disabled before touching anything, so no entry point (promotion, WhatsApp Web amendment or proven-LID move, sweep,
# revert) can move a chat while it is off. Under the locks the recipient must hold the number as its primary.
class Contacts::NumberHistoryTransferService # rubocop:disable Metrics/ClassLength
  MAX_LOG_ENTRIES = 20
  # whatsapp_account: a WhatsApp Web LID chat proven (phone JID + LID in one payload) to be the same account as a
  # phone-JID chat of a patient card, moved to that card instead of merging contacts (WhatsappWeb::ContactSyncService).
  BASES = %w[medelement administrator whatsapp_account].freeze
  CONVERSATION_TABLES = %w[calls telephony_call_sessions csat_survey_responses meta_ad_referrals lead_submissions].freeze
  TRANSFERS_KEY = Contacts::SharedPhone::TRANSFERS_KEY
  Result = Data.define(:entry, :created)

  class Error < StandardError; end
  # ONELINK_SHARED_PHONE_HISTORY_TRANSFER is off (Contacts::SharedPhoneSwitches): nothing is moved or logged.
  class Disabled < Error; end

  attr_reader :account, :phone, :from, :to, :basis, :actor

  # contact_inbox_ids: an explicit set (amendment of a recorded transfer, e.g. a WhatsApp Web LID proven tied later);
  # by default every identifying ContactInbox of the number owned by `from`.
  # rubocop:disable Metrics/ParameterLists
  def initialize(account:, phone:, from:, to:, basis:, actor: nil, promoted: false, contact_inbox_ids: nil, amendment_of: nil)
    @account = account
    @phone = phone
    @from = from
    @to = to
    @basis = basis.to_s
    @actor = actor
    @promoted = promoted
    @explicit_contact_inbox_ids = contact_inbox_ids
    @amendment_of = amendment_of
  end
  # rubocop:enable Metrics/ParameterLists

  def self.enabled? = Contacts::SharedPhoneSwitches.history_transfer?

  def perform!
    raise Disabled, 'Number history transfer is switched off' unless self.class.enabled?

    validate!
    result = ActiveRecord::Base.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      lock_contacts!
      next Result.new(entry: nil, created: false) unless self.class.recipient_holds_number?(to, phone)

      contact_inboxes = selected_contact_inboxes
      next Result.new(entry: nil, created: false) if contact_inboxes.empty?

      Result.new(entry: move!(contact_inboxes), created: true)
    end
    schedule_follow_up(result.entry) if result.created
    result
  end

  def self.find_entry(contact, transfer_id, direction: 'in')
    Array(contact.custom_attributes.to_h[TRANSFERS_KEY]).find { |entry| entry['id'] == transfer_id.to_s && entry['direction'] == direction }
  end

  # A WhatsApp Web payload that carries both JIDs proves that a LID chat belongs to the same account as a phone-JID chat
  # moved by a recorded transfer: the LID chat (still with the previous holder) joins it as an amendment of that transfer.
  # Only while history transfer is switched on, and only while the recipient still holds the number as its primary
  # (nobody else does): a recipient that released the number (staff corrected it, or gave it back) is no proof, and the
  # previous holder's chat stays where it is (M6, M7). Runs inside the inbound WhatsApp Web sync, so a refused or failed
  # amendment is logged and never raised: the incoming message must still be stored.
  def self.amend_tied_lid!(contact_inbox:, lid_source_id:)
    entry = amendable_entry(contact_inbox, lid_source_id)
    lid = entry && tied_lid_contact_inbox(contact_inbox, lid_source_id, entry)
    return if lid.blank?

    to = contact_inbox.contact
    from = Contact.find_by(id: lid.contact_id, account_id: to.account_id)
    new(account: to.account, phone: entry['phone'], from: from, to: to, basis: entry['basis'], contact_inbox_ids: [lid.id],
        amendment_of: entry['id']).perform!
  rescue Error => e
    Rails.logger.warn({ event: 'number_history_transfer_amendment_skipped', contact_inbox_id: contact_inbox&.id, error: e.message }.to_json)
    nil
  end

  def self.amendable_entry(contact_inbox, lid_source_id)
    return unless enabled? && lid_source_id.present?

    entry = recorded_entry_for(contact_inbox)
    entry if entry && recipient_holds_number?(contact_inbox.contact, entry['phone'])
  end

  def self.tied_lid_contact_inbox(contact_inbox, lid_source_id, entry)
    lid = ContactInbox.find_by(inbox_id: contact_inbox.inbox_id, source_id: lid_source_id)
    lid if lid && lid.contact_id == entry['counterpart_contact_id']
  end

  # The recorded incoming transfer (not a revert, not reverted) that moved this ContactInbox to its contact.
  def self.recorded_entry_for(contact_inbox)
    Array(contact_inbox&.contact&.custom_attributes.to_h[TRANSFERS_KEY]).find { |item| amendable_log_entry?(item, contact_inbox.id) }
  end

  def self.amendable_log_entry?(item, contact_inbox_id)
    return false unless item['direction'] == 'in' && BASES.include?(item['basis'])

    item['reverted_at'].blank? && item['revert_of'].blank? && Array(item['contact_inbox_ids']).include?(contact_inbox_id)
  end

  # M1/M6: a number's chats only ever move to the contact that holds it as primary, and only while nobody else does.
  def self.recipient_holds_number?(contact, phone)
    contact.present? && phone.present? && contact.phone_number == phone &&
      Contacts::SharedPhone.primary_holder(account_id: contact.account_id, phone: phone, excluding: [contact.id]).blank?
  end

  # SQL that moves the rows of one CONVERSATION_TABLES table tied to the given chats from one contact to another (the
  # revert passes the contacts swapped) and returns their ids. Lead submissions also follow their ContactInbox. Every
  # value is bound, the table name comes from the allow-list.
  def self.conversation_rows_update_sql(table, from_id:, to_id:, conversation_ids:, contact_inbox_ids:)
    raise ArgumentError, "Unknown conversation table #{table}" unless CONVERSATION_TABLES.include?(table)

    lead_submissions = table == 'lead_submissions'
    scope = lead_submissions ? 'conversation_id IN (?) OR contact_inbox_id IN (?)' : 'conversation_id IN (?)'
    binds = [to_id.to_i, from_id.to_i, Array(conversation_ids).map(&:to_i)]
    binds << Array(contact_inbox_ids).map(&:to_i) if lead_submissions
    ActiveRecord::Base.sanitize_sql_array(
      ["UPDATE #{ActiveRecord::Base.connection.quote_table_name(table)} SET contact_id = ? WHERE contact_id = ? AND (#{scope}) RETURNING id", *binds]
    )
  end

  # SQL selecting the telephony endpoints of a contact for the number (stored with or without its leading +).
  def self.endpoint_ids_sql(contact_id:, phone:)
    ActiveRecord::Base.sanitize_sql_array(
      ['SELECT id FROM telephony_contact_endpoints WHERE contact_id = ? AND endpoint_value IN (?)', contact_id.to_i,
       [phone, Contacts::SharedPhone.digits(phone)]]
    )
  end

  def self.append_log!(contact, entry)
    attributes = contact.reload.custom_attributes.to_h
    attributes[TRANSFERS_KEY] = ([entry] + Array(attributes[TRANSFERS_KEY])).first(MAX_LOG_ENTRIES)
    contact.update_columns(custom_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def self.update_log!(contact, transfer_id)
    attributes = contact.reload.custom_attributes.to_h
    attributes[TRANSFERS_KEY] = Array(attributes[TRANSFERS_KEY]).map { |item| item['id'] == transfer_id ? yield(item.dup) : item }
    contact.update_columns(custom_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  # parties: [from, to]
  def self.activity_content(account:, key:, phone:, parties:, actor:, at:) # rubocop:disable Metrics/ParameterLists
    from, to = parties
    timezone = account.try(:reporting_timezone).presence || 'Asia/Almaty'
    I18n.with_locale(account.locale.presence || I18n.default_locale) do
      I18n.t("conversations.activity.number_history_transfer.#{key}",
             phone: Contacts::SharedPhone.mask(phone), from: from.name.presence || "##{from.id}", to: to.name.presence || "##{to.id}",
             user_name: actor.try(:name).presence || I18n.t('automation.system_name'), time: at.in_time_zone(timezone).strftime('%d.%m.%Y %H:%M'))
    end
  end

  private

  def validate!
    raise Error, 'Unknown transfer basis' unless BASES.include?(basis)
    raise Error, 'Transfer number is required' if phone.blank?

    validate_parties!
  end

  def validate_parties!
    raise Error, 'Transfer contacts must differ' if from.blank? || to.blank? || from.id == to.id
    raise Error, 'Transfer contacts must belong to the account' unless [from, to].all? { |contact| contact.account_id == account.id }
  end

  # Contacts and ContactInboxes are locked FOR NO KEY UPDATE: nothing here changes a key column before lock_touches! has
  # waited out every in-flight delivery (identifier moves only afterwards). A touch execution that holds its touch row
  # re-checks the foreign keys of its row (target contact, target ContactInbox) with FOR KEY SHARE when it updates the
  # touch again in its own transaction; FOR UPDATE here made that wait for the transfer while the transfer waited for the
  # touch row (sc8rv2 C6 deadlock). Every other writer of these rows still serializes with the transfer.
  def lock_contacts!
    Contact.where(id: [from.id, to.id]).order(:id).lock('FOR NO KEY UPDATE').to_a
    from.reload
    to.reload
  end

  def selected_contact_inboxes
    scope = if @explicit_contact_inbox_ids
              ContactInbox.where(id: @explicit_contact_inbox_ids)
            else
              Contacts::SharedPhone.identifying_contact_inboxes(account_id: account.id, phone: phone, owner_ids: [from.id])
            end
    scope.where(contact_id: from.id).order(:id).lock('FOR NO KEY UPDATE').to_a
  end

  def move!(contact_inboxes)
    now = Time.current
    ci_ids = contact_inboxes.map(&:id)
    lock_touches!(ci_ids)
    conversation_ids = Conversation.where(account_id: account.id, contact_inbox_id: ci_ids).order(:id).lock('FOR NO KEY UPDATE').pluck(:id)
    threads_before = thread_ids(conversation_ids)

    moved = move_history!(ci_ids, conversation_ids, now)
    moved['moved_identifier'] = move_identifier!(contact_inboxes)
    moved.merge!(move_reminders!(ci_ids, conversation_ids))
    moved['thread_moves'] = refresh_threads!(conversation_ids, threads_before)
    entry = log_entry(ci_ids, conversation_ids, moved, now)
    write_log!(entry)
    create_activity_messages!(conversation_ids, now)
    entry
  end

  # rubocop:disable Rails/SkipsModelValidations
  def move_history!(ci_ids, conversation_ids, now)
    ContactInbox.where(id: ci_ids).update_all(contact_id: to.id, updated_at: now)
    ContactChannelProfile.where(contact_inbox_id: ci_ids).update_all(contact_id: to.id, updated_at: now)
    Conversation.where(id: conversation_ids).update_all(contact_id: to.id, updated_at: now)
    rows = move_conversation_rows!(ci_ids, conversation_ids)
    messages = Message.where(conversation_id: conversation_ids, sender_type: 'Contact', sender_id: from.id)
                      .update_all(sender_id: to.id, updated_at: now)
    { 'moved_message_count' => messages, 'telephony_endpoint_ids' => move_endpoints!, 'conversation_rows' => rows }
  end
  # rubocop:enable Rails/SkipsModelValidations

  # Rows tied to the moved chats (calls, call sessions, CSAT answers, ad referrals, lead submissions) follow them; the
  # moved ids per table are recorded so the revert returns exactly these rows (M6: traced and revertible).
  def move_conversation_rows!(ci_ids, conversation_ids)
    CONVERSATION_TABLES.each_with_object({}) do |table, moved|
      next unless connection.data_source_exists?(table)

      ids = connection.select_values(
        self.class.conversation_rows_update_sql(table, from_id: from.id, to_id: to.id, conversation_ids: conversation_ids, contact_inbox_ids: ci_ids)
      )
      moved[table] = ids.map(&:to_i).sort if ids.any?
    end
  end

  def move_endpoints!
    return [] unless connection.data_source_exists?('telephony_contact_endpoints')

    ids = connection.select_values(self.class.endpoint_ids_sql(contact_id: from.id, phone: phone))
    return ids if ids.empty?

    connection.update(
      ActiveRecord::Base.sanitize_sql_array(['UPDATE telephony_contact_endpoints SET contact_id = ? WHERE id IN (?)', to.id, ids.map(&:to_i)])
    )
    ids
  end

  # The WhatsApp Web LID identifier follows its tied LID chat; it is always cleared from `from` so the builder can never
  # file a new chat of that account under the previous holder, and given to `to` only when `to` has no identifier.
  def move_identifier!(contact_inboxes)
    identifier = from.identifier.to_s
    lid = identifier.delete_prefix('whatsapp_web:')
    return if identifier == lid || contact_inboxes.none? { |contact_inbox| contact_inbox.source_id == lid }

    from.update_columns(identifier: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    applied = to.identifier.blank?
    to.update_columns(identifier: identifier, updated_at: Time.current) if applied # rubocop:disable Rails/SkipsModelValidations
    { 'value' => identifier, 'applied_to_recipient' => applied }
  end

  # Every open touch of `from` and every touch aimed at a moved chat, locked before the conversations. A touch that is
  # being delivered holds its row until its message is materialized, so it is classified below with its final state.
  def lock_touches!(ci_ids)
    conversation_ids = Conversation.where(account_id: account.id, contact_inbox_id: ci_ids).pluck(:id)
    scope = Reminder.where(account_id: account.id, target_contact_id: from.id)
    scope.where(status: Reminder::OPEN_STATUSES).or(scope.where(target_contact_inbox_id: ci_ids))
         .or(scope.where(target_conversation_id: conversation_ids)).order(:id).lock.pluck(:id)
  end

  # Settled touches (finished, or processing with a materialized message) keep their history but follow their chat
  # (target associations stay consistent). Open touches that belong to a moved chat (an agent's follow-up scheduled in
  # it: remindable = that conversation) follow the chat too, with their ContactInbox and conversation. Only open touches
  # of `from`'s own entities (appointments, deals, tasks, the contact) drop the moved chat and re-resolve at sync or send
  # time (M6: what is not tied to the number stays with the previous holder).
  # rubocop:disable Rails/SkipsModelValidations
  def move_reminders!(ci_ids, conversation_ids)
    touches = classify_touches(touched_reminders(ci_ids, conversation_ids), conversation_ids)
    following = touches['settled_reminder_ids'] + touches['followed_open_reminder_ids']
    Reminder.where(id: following).update_all(target_contact_id: to.id) if following.any?
    cleared = touches['cleared_open_reminder_ids']
    Reminder.where(id: cleared).update_all(target_contact_inbox_id: nil, target_conversation_id: nil) if cleared.any?
    touches
  end
  # rubocop:enable Rails/SkipsModelValidations

  def classify_touches(scope, conversation_ids)
    materialized = scope.where(status: :processing).where('reminders.metadata ->> ? IS NOT NULL', Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY)
    settled = scope.where.not(status: Reminder::OPEN_STATUSES).or(materialized).pluck(:id)
    open = scope.where(status: Reminder::OPEN_STATUSES).where.not(id: settled)
    followed = open.where(remindable_type: 'Conversation', remindable_id: conversation_ids).pluck(:id)
    { 'settled_reminder_ids' => settled, 'followed_open_reminder_ids' => followed,
      'cleared_open_reminder_ids' => open.where(status: %w[draft pending]).where.not(id: followed).pluck(:id) }
  end

  def touched_reminders(ci_ids, conversation_ids)
    table = Reminder.arel_table
    Reminder.where(account_id: account.id, target_contact_id: from.id)
            .where(table[:target_contact_inbox_id].in(ci_ids).or(table[:target_conversation_id].in(conversation_ids)))
  end

  def thread_ids(conversation_ids)
    return {} unless connection.data_source_exists?('communication_thread_conversations')

    CommunicationThreadConversation.where(conversation_id: conversation_ids).pluck(:conversation_id, :communication_thread_id).to_h
  end

  def refresh_threads!(conversation_ids, before)
    Conversation.where(id: conversation_ids).find_each(&:refresh_communication_thread!)
    after = thread_ids(conversation_ids)
    update_referral_threads!(after)
    conversation_ids.filter_map do |id|
      next if before[id] == after[id]

      { 'conversation_id' => id, 'from_thread_id' => before[id], 'to_thread_id' => after[id] }
    end
  end

  def update_referral_threads!(threads)
    return unless connection.data_source_exists?('meta_ad_referrals')

    threads.each do |conversation_id, thread_id|
      connection.update("UPDATE meta_ad_referrals SET communication_thread_id = #{thread_id.to_i} WHERE conversation_id = #{conversation_id.to_i}")
    end
  end

  def log_entry(ci_ids, conversation_ids, moved, now)
    moved.merge(
      'id' => SecureRandom.uuid, 'key' => transfer_key(ci_ids), 'phone' => phone, 'contact_inbox_ids' => ci_ids,
      'conversation_ids' => conversation_ids, 'basis' => basis, 'actor' => actor_payload, 'at' => now.iso8601,
      'promoted' => @promoted, 'amendment_of' => @amendment_of, 'reverted_at' => nil, 'reverted_by' => nil, 'revert_of' => nil
    )
  end

  def transfer_key(ci_ids)
    Digest::SHA256.hexdigest([account.id, phone, from.id, to.id, ci_ids.sort].flatten.join(':'))
  end

  def actor_payload
    actor.is_a?(User) ? { 'type' => 'User', 'id' => actor.id } : { 'type' => 'system', 'id' => nil }
  end

  def write_log!(entry)
    self.class.append_log!(to, entry.merge('direction' => 'in', 'counterpart_contact_id' => from.id))
    self.class.append_log!(from, entry.merge('direction' => 'out', 'counterpart_contact_id' => to.id))
  end

  def create_activity_messages!(conversation_ids, now)
    content = self.class.activity_content(account: account, key: basis, phone: phone, parties: [from, to], actor: actor, at: now)
    Conversation.where(id: conversation_ids).find_each do |conversation|
      conversation.messages.create!(account_id: account.id, inbox_id: conversation.inbox_id, message_type: :activity, content: content)
    end
  end

  def schedule_follow_up(entry)
    account_id = account.id
    to_id = to.id
    from_id = from.id
    ActiveRecord.after_all_transactions_commit do
      Contacts::NumberHistoryTransferSweepJob.perform_later(account_id, to_id, entry['id'])
      Contacts::NumberHistoryTransferSweepJob.set(wait: 2.minutes).perform_later(account_id, to_id, entry['id'])
      Contact.where(id: [from_id, to_id]).find_each(&:dispatch_shared_phone_update_event)
    end
  end

  def connection = ActiveRecord::Base.connection
end
