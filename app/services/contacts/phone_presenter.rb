class Contacts::PhonePresenter
  VirtualEntry = Data.define(:id, :phone_number, :primary, :shared, :label, :owner_contact_id)

  def self.present(contact, include_related: false)
    new(contact, include_related: include_related).present
  end

  def initialize(contact, include_related: false)
    @contact = contact
    @include_related = include_related
  end

  def present
    return [] if contact.blank?

    rows = resolved_entries
    return [] if rows.empty?
    return rows.map { |entry| serialize_basic(entry) } unless include_related && contact.account_id.present?

    serialize_with_relations(rows)
  end

  private

  attr_reader :contact, :include_related

  def resolved_entries
    loaded = loaded_contact_phones
    return fallback_entries if loaded.empty?

    loaded = [primary_virtual_entry] + loaded if missing_primary_row?(loaded)
    loaded.sort_by { |row| [sort_rank(row), row.id || 0] }
  end

  def loaded_contact_phones
    return [] unless contact.persisted?

    contact.contact_phones.to_a.reject { |row| row.primary && row.phone_number != contact.phone_number }
  end

  def missing_primary_row?(loaded)
    contact.phone_number.present? && loaded.none? { |row| row.phone_number == contact.phone_number }
  end

  def sort_rank(row)
    return 0 if row.primary
    return 1 unless row.shared

    2
  end

  def primary_virtual_entry
    VirtualEntry.new(
      id: nil,
      phone_number: contact.phone_number,
      primary: true,
      shared: false,
      label: nil,
      owner_contact_id: nil
    )
  end

  def fallback_entries
    list = []
    list << primary_virtual_entry if contact.phone_number.present?
    share = Contacts::SharedPhone.share_of(contact)
    if share.present? && share.phone.present? && share.phone != contact.phone_number
      list << VirtualEntry.new(
        id: nil,
        phone_number: share.phone,
        primary: false,
        shared: true,
        label: nil,
        owner_contact_id: share.owner_id
      )
    end
    list
  end

  def serialize_basic(entry)
    {
      id: entry.id,
      phone_number: entry.phone_number,
      primary: entry.primary,
      shared: entry.shared,
      label: entry.label,
      owner_contact_id: entry.owner_contact_id,
      owner_contact: nil,
      shared_contacts: []
    }
  end

  def serialize_with_relations(rows)
    peer_rows = fetch_peer_rows(rows)
    contacts_by_id = build_contacts_index(rows, peer_rows)
    rows.map { |entry| serialize_related_entry(entry, peer_rows, contacts_by_id) }
  end

  def fetch_peer_rows(rows)
    phones = rows.map(&:phone_number).compact_blank.uniq
    ContactPhone.includes(:contact)
                .where(account_id: contact.account_id, phone_number: phones)
                .where.not(contact_id: contact.id)
                .to_a
  end

  def build_contacts_index(rows, peer_rows)
    contacts_by_id = peer_rows.filter_map(&:contact).index_by(&:id)
    missing_ids = rows.filter_map(&:owner_contact_id).uniq - contacts_by_id.keys
    Contact.where(account_id: contact.account_id, id: missing_ids).find_each do |owner|
      contacts_by_id[owner.id] = owner
    end
    contacts_by_id
  end

  def serialize_related_entry(entry, peer_rows, contacts_by_id)
    peers = peer_rows.select { |row| row.phone_number == entry.phone_number }
    owner_record = resolve_owner_record(entry, peers, contacts_by_id)
    shared_peers = resolve_shared_peers(peers, owner_record)

    serialize_basic(entry).merge(
      owner_contact_id: owner_record&.id || entry.owner_contact_id,
      owner_contact: owner_record ? summary_payload(owner_record) : nil,
      shared_contacts: shared_peers.map { |peer| summary_payload(peer) }
    )
  end

  def resolve_shared_peers(peers, owner_record)
    excluded_ids = [contact.id, owner_record&.id].compact
    peers.filter_map(&:contact).uniq(&:id).reject { |peer| excluded_ids.include?(peer.id) }
  end

  def resolve_owner_record(entry, peers_for_phone, contacts_by_id)
    return unless entry.shared

    contacts_by_id[entry.owner_contact_id] ||
      peers_for_phone.find { |row| !row.shared? }&.contact ||
      Contacts::SharedPhone.primary_holder(
        account_id: contact.account_id,
        phone: entry.phone_number,
        excluding: [contact.id]
      )
  end

  def summary_payload(record)
    {
      id: record.id,
      name: record.display_full_name
    }
  end
end
