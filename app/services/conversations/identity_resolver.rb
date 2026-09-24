require 'digest'

class Conversations::IdentityResolver
  PRIMARY_KEY = 'primary'.freeze
  class ContactChanged < StandardError; end

  def self.resolve_primary!(contact_inbox:, attributes:, &)
    new(contact_inbox: contact_inbox, identity_key: PRIMARY_KEY, attributes: attributes).perform(&)
  end

  def initialize(contact_inbox:, identity_key:, attributes:)
    @contact_inbox = contact_inbox
    @identity_key = identity_key.to_s.strip
    @attributes = attributes.to_h.symbolize_keys
  end

  def perform
    validate_inputs!

    with_current_contact_lock do
      lock_identity!
      existing_conversation = conversation_scope.reload.find_by(identity_key: identity_key)
      next reconcile_contact_inbox!(existing_conversation) if existing_conversation.present?

      claim_legacy_conversation || create_conversation { |conversation| yield conversation if block_given? }
    end
  rescue ActiveRecord::RecordNotUnique
    conversation_scope.find_by!(identity_key: identity_key)
  end

  private

  attr_reader :contact_inbox, :identity_key, :attributes

  def with_current_contact_lock
    loop do
      contact_id = ContactInbox.where(id: contact_inbox.id).pick(:contact_id)
      begin
        return Conversation.transaction(requires_new: true) do
          # The create callback can update Contact.owner and its appointments.
          # Match ContactMergeAction and appointment linking: Contact -> CI -> identity.
          Contact.lock.find(contact_id)
          contact_inbox.lock!
          raise ContactChanged if contact_inbox.contact_id != contact_id

          yield
        end
      rescue ContactChanged, ActiveRecord::RecordNotFound
        # A merge may move this identity while we wait for the old Contact.
        # Roll back the savepoint (and its locks), then use the new owner.
        raise if ContactInbox.where(id: contact_inbox.id).pick(:contact_id) == contact_id
      end
    end
  end

  def validate_inputs!
    raise ArgumentError, 'contact_inbox is required' if contact_inbox.blank?
    raise ArgumentError, 'identity_key is required' if identity_key.blank?
    raise ArgumentError, 'identity_key is too long' if identity_key.length > 255
  end

  def conversation_scope
    Conversation.where(
      account_id: contact_inbox.inbox.account_id,
      inbox_id: contact_inbox.inbox_id,
      contact_id: contact_inbox.contact_id
    ).reorder(Arel.sql('campaign_id IS NULL DESC'), Arel.sql('last_activity_at DESC NULLS LAST'), created_at: :desc, id: :desc)
  end

  def lock_identity!
    lock_id = Digest::SHA256.digest(identity_lock_key).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end

  def identity_lock_key
    [contact_inbox.inbox.account_id, contact_inbox.inbox_id, contact_inbox.contact_id, identity_key].join(':')
  end

  def claimable_legacy_conversation
    return unless identity_key == PRIMARY_KEY

    conversation_scope.where(identity_key: nil).first
  end

  def claim_legacy_conversation
    conversation = claimable_legacy_conversation
    return if conversation.blank?

    conversation.update!(
      identity_key: identity_key,
      contact_inbox: contact_inbox,
      additional_attributes: reconciled_additional_attributes(conversation)
    )
    conversation
  end

  def reconcile_contact_inbox!(conversation)
    return conversation if conversation.contact_inbox_id == contact_inbox.id

    conversation.update!(
      contact_inbox: contact_inbox,
      additional_attributes: reconciled_additional_attributes(conversation)
    )
    conversation
  end

  def reconciled_additional_attributes(conversation)
    current_attributes = conversation.additional_attributes || {}
    incoming_attributes = attributes[:additional_attributes].to_h
    current_attributes.merge(incoming_attributes)
  end

  def create_conversation
    conversation = Conversation.create!(canonical_attributes)
    yield conversation if block_given?
    conversation
  end

  def canonical_attributes
    attributes.except(:account_id, :contact_id, :contact_inbox_id, :identity_key).merge(
      account_id: contact_inbox.inbox.account_id,
      inbox_id: contact_inbox.inbox_id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      identity_key: identity_key
    )
  end
end
