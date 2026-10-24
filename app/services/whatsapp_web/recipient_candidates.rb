# Ordered remote JID candidates for the contact behind a WhatsApp Web conversation.
#
# The conversation may hang on a @lid contact inbox while the same contact also owns a phone identity (another
# contact inbox / channel profile in the same inbox). Callers pick the first routable candidate (not @lid) and fall back
# to a @lid candidate only when nothing else is left, so the order is: the matched profile and contact attributes, the
# conversation's own source id, the phone identities of the same contact (ones tied to this LID first), and finally the
# contact's phone number.
class WhatsappWeb::RecipientCandidates
  LID_SUFFIX = '@lid'.freeze

  pattr_initialize [:conversation!]

  def to_a
    [*own_candidates, *sibling_candidates, contact&.phone_number]
      .filter_map { |value| value.to_s.strip.presence }
      .uniq
  end

  private

  delegate :contact, :contact_inbox, to: :conversation

  def own_candidates
    [
      matched_profile&.[](:canonical_jid),
      matched_profile&.[](:raw_jid),
      contact_attributes[:canonical_jid],
      contact_attributes[:raw_jid],
      contact_inbox&.source_id
    ]
  end

  def sibling_candidates
    identities = legacy_sibling_identities + contact_inbox_sibling_identities
    identities.sort_by.with_index { |identity, index| [identity[:tied] ? 0 : 1, index] }.flat_map { |identity| identity[:jids] }
  end

  def contact_attributes
    @contact_attributes ||= (contact&.additional_attributes || {}).with_indifferent_access
  end

  def legacy_profiles
    @legacy_profiles ||= contact_attributes[:channel_profiles].to_h.with_indifferent_access[:whatsapp_web]
                                                              .to_h.with_indifferent_access.values
                                                              .map { |profile| profile.to_h.with_indifferent_access }
  end

  def matched_profile
    return @matched_profile if defined?(@matched_profile)

    wanted = contact_inbox&.source_id.to_s.strip.presence || contact&.identifier.to_s.strip
    @matched_profile = legacy_profiles.find { |profile| profile_identifiers(profile).include?(wanted) } || legacy_profiles.first
  end

  def profile_identifiers(profile)
    profile.values_at(:source_id, :identifier, :canonical_jid, :raw_jid, :lid_jid).map { |value| value.to_s.strip }.compact_blank
  end

  def current_lid
    source_id = contact_inbox&.source_id.to_s.strip
    source_id if source_id.end_with?(LID_SUFFIX)
  end

  def legacy_sibling_identities
    (legacy_profiles - [matched_profile]).map do |profile|
      { tied: tied_to_current_lid?(profile[:lid_jid]), jids: [profile[:canonical_jid], profile[:source_id]] }
    end
  end

  def contact_inbox_sibling_identities
    siblings = sibling_contact_inboxes
    profiles = ContactChannelProfile.where(contact_inbox_id: siblings.map(&:id)).index_by(&:contact_inbox_id)
    siblings.map do |sibling|
      profile_data = (profiles[sibling.id]&.profile_data || {}).to_h.with_indifferent_access
      { tied: tied_to_current_lid?(profile_data[:lid_jid]), jids: [profile_data[:canonical_jid], sibling.source_id] }
    end
  end

  def sibling_contact_inboxes
    return [] if contact.blank? || conversation.inbox_id.blank?

    contact.contact_inboxes.where(inbox_id: conversation.inbox_id).where.not(id: contact_inbox&.id).order(:id).to_a
  end

  def tied_to_current_lid?(lid_jid)
    current_lid.present? && lid_jid.to_s.strip == current_lid
  end
end
