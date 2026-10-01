# The single promotion entry point (M5): a card's доп. номер becomes its own primary, and the chat history of that number
# moves from its previous holder to the card (M6, Contacts::NumberHistoryTransferService) in the same transaction.
#
# basis 'medelement' (a): re-checks Contacts::SharedPhonePromotionPolicy under the phone identity lock.
# basis 'administrator' (b): the number must still be the card's доп. номер and free; the preview fingerprint the
# administrator confirmed must still match (STATE_CHANGED otherwise), and a number someone else took meanwhile (for
# example a sibling promoted a second earlier) is TAKEN. Nothing here runs on deploy or as a mass job.
#
# Switches (Contacts::SharedPhoneSwitches, all off by default): basis 'medelement' runs only with
# ONELINK_SHARED_PHONE_AUTO_PROMOTION (the policy blocks it otherwise), basis 'administrator' only with
# ONELINK_SHARED_PHONE_MANUAL_PROMOTION (PROMOTION_DISABLED otherwise), and a promotion that would move a previous
# holder's chats only with ONELINK_SHARED_PHONE_HISTORY_TRANSFER.
class Contacts::SharedPhonePromotionService
  MAX_ATTEMPTS = 3
  PROMOTION_DISABLED = 'SHARED_PHONE_PROMOTION_DISABLED'.freeze
  HISTORY_TRANSFER_DISABLED = 'SHARED_PHONE_HISTORY_TRANSFER_DISABLED'.freeze
  DISABLED_CODES = [PROMOTION_DISABLED, HISTORY_TRANSFER_DISABLED].freeze
  Result = Data.define(:status, :reason, :entry, :moved)

  class Error < StandardError
    attr_reader :code

    def initialize(code, message = code)
      @code = code
      super(message)
    end
  end

  def initialize(card:, basis:, actor: nil, expected_fingerprint: nil)
    @card = card
    @basis = basis.to_s
    @actor = actor
    @expected_fingerprint = expected_fingerprint
  end

  def perform
    raise Error.new(PROMOTION_DISABLED, 'Manual promotion of a shared number is switched off') if manual_promotion_disabled?

    attempts = 0
    begin
      attempts += 1
      ActiveRecord::Base.transaction { promote_locked! }
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      raise if attempts >= MAX_ATTEMPTS

      sleep(rand(0.05..0.2))
      retry
    end
  end

  def self.previous_holder_for(card, phone)
    hint_holder_id = card.custom_attributes.to_h.dig(Contacts::SharedPhone::HINT_KEY, 'previous_holder_contact_id')
    share_owner_id = Contacts::SharedPhone.share_of(card)&.owner_id
    holders = Contacts::SharedPhone.identity_owner_ids(account_id: card.account_id, phone: phone, excluding: [card.id])
    holder_id = [hint_holder_id, share_owner_id].compact.map(&:to_i).find { |id| holders.include?(id) }
    holder_id ||= holders.first if holders.one?
    Contact.find_by(id: holder_id, account_id: card.account_id) if holder_id
  end

  def self.promotable_phone(card)
    hint_phone = card.custom_attributes.to_h.dig(Contacts::SharedPhone::HINT_KEY, 'phone')
    phone = hint_phone.presence || Contacts::SharedPhone.share_of(card)&.phone
    phone if phone.present? && Contacts::SharedPhone.secondary_phones(card).include?(phone)
  end

  private

  # Contact rows are locked FOR NO KEY UPDATE (the promotion changes phone_number and custom_attributes, no key column),
  # like the transfer: a touch execution's foreign key re-check (FOR KEY SHARE) is never blocked by them.
  def promote_locked!
    Contacts::PhoneIdentityLock.acquire!(account_id: @card.account_id)
    card = Contact.lock('FOR NO KEY UPDATE').find(@card.id)
    phone = self.class.promotable_phone(card)
    return Result.new(status: :noop, reason: :already_primary, entry: nil, moved: nil) if phone.blank? && card.phone_number.present?
    raise Error, 'SHARED_PHONE_NOT_ELIGIBLE' if phone.blank?

    previous = @basis == 'medelement' ? medelement_previous_holder(card) : administrator_previous_holder(card, phone)
    return previous if previous.is_a?(Result)

    Contact.where(id: [card.id, previous&.id].compact).order(:id).lock('FOR NO KEY UPDATE').to_a
    promote!(card, phone, previous)
  end

  def medelement_previous_holder(card)
    decision = Contacts::SharedPhonePromotionPolicy.auto_decision(card)
    return Result.new(status: :blocked, reason: decision.reason, entry: nil, moved: nil) unless decision.promote?

    decision.previous_holder
  end

  def administrator_previous_holder(card, phone)
    raise Error, 'SHARED_PHONE_TAKEN' if Contacts::SharedPhone.primary_holder(account_id: card.account_id, phone: phone, excluding: [card.id])
    if Contacts::PatientIdentityMergeGuard.patient_binding_write_in_flight?(card)
      raise Error.new('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION', 'A MedElement write for this patient is in progress')
    end

    previous = self.class.previous_holder_for(card, phone)
    preview = Contacts::NumberHistoryTransferPreview.new(account: card.account, phone: phone, card: card, previous_holder: previous)
    raise Error, 'SHARED_PHONE_STATE_CHANGED' if @expected_fingerprint.blank? || preview.fingerprint != @expected_fingerprint
    if previous && !Contacts::SharedPhoneSwitches.history_transfer?
      raise Error.new(HISTORY_TRANSFER_DISABLED, 'Moving the chat history of a shared number is switched off')
    end

    previous
  end

  def manual_promotion_disabled? = @basis == 'administrator' && !Contacts::SharedPhoneSwitches.manual_promotion?

  def promote!(card, phone, previous)
    card.phone_number = phone
    card.custom_attributes = card.custom_attributes.to_h.merge('secondary_phones' => Contacts::SharedPhone.secondary_phones(card) - [phone])
    card.save!
    transfer = if previous
                 Contacts::NumberHistoryTransferService.new(account: card.account, phone: phone, from: previous, to: card, basis: @basis,
                                                            actor: @actor, promoted: true).perform!
               end
    entry = transfer&.entry || record_promotion_only!(card, phone)
    Result.new(status: :promoted, reason: nil, entry: entry, moved: moved_counts(transfer&.entry))
  end

  def record_promotion_only!(card, phone)
    entry = { 'id' => SecureRandom.uuid, 'direction' => 'in', 'phone' => phone, 'counterpart_contact_id' => nil, 'contact_inbox_ids' => [],
              'conversation_ids' => [], 'moved_message_count' => 0, 'basis' => @basis, 'promoted' => true, 'at' => Time.current.iso8601,
              'actor' => @actor.is_a?(User) ? { 'type' => 'User', 'id' => @actor.id } : { 'type' => 'system', 'id' => nil } }
    Contacts::NumberHistoryTransferService.append_log!(card, entry)
    entry
  end

  def moved_counts(entry)
    return { contact_inboxes: 0, conversations: 0, messages: 0 } if entry.blank?

    { contact_inboxes: entry['contact_inbox_ids'].size, conversations: entry['conversation_ids'].size, messages: entry['moved_message_count'] }
  end
end
