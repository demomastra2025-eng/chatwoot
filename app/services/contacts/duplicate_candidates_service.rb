# rubocop:disable Metrics/ClassLength
class Contacts::DuplicateCandidatesService
  DISMISSED_KEY = 'dismissed_duplicate_contact_ids'.freeze
  MAX_PAIRS = 200
  MAX_NAME_GROUP_SIZE = 10

  IIN_SQL_EXPR = <<~SQL.squish.freeze
    COALESCE(
      NULLIF(regexp_replace(custom_attributes ->> 'iin', '\\D', '', 'g'), ''),
      NULLIF(regexp_replace(custom_attributes ->> 'medelement_iin', '\\D', '', 'g'), ''),
      CASE WHEN identifier ~ '^\\d{12}$' THEN identifier END
    )
  SQL

  FIRST_NAME_SQL_EXPR = <<~SQL.squish.freeze
    LOWER(TRANSLATE(TRIM(COALESCE(
      NULLIF(custom_attributes ->> 'medelement_first_name', ''),
      NULLIF(SPLIT_PART(TRIM(name), ' ', 1), '')
    )), 'Ёё', 'ее'))
  SQL

  LAST_NAME_SQL_EXPR = <<~SQL.squish.freeze
    LOWER(TRANSLATE(TRIM(COALESCE(
      NULLIF(custom_attributes ->> 'medelement_last_name', ''),
      NULLIF(last_name, ''),
      NULLIF(SPLIT_PART(TRIM(name), ' ', 2), '')
    )), 'Ёё', 'ее'))
  SQL

  SECONDARY_PHONE_OWNER_SQL = <<~SQL.squish.freeze
    SELECT c1.id, c2.id
    FROM contacts c1
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE
        WHEN jsonb_typeof(c1.custom_attributes -> 'secondary_phones') = 'array'
        THEN c1.custom_attributes -> 'secondary_phones'
        ELSE '[]'::jsonb
      END
    ) AS sec_phone
    INNER JOIN contacts c2
      ON c2.account_id = c1.account_id
     AND c2.phone_number = sec_phone
     AND c2.id <> c1.id
    WHERE c1.account_id = :account_id
    LIMIT :limit
  SQL

  def initialize(account:)
    @account = account
  end

  def perform
    pairs = collect_candidate_pairs
    return [] if pairs.empty?

    contact_ids = pairs.flatten.uniq
    contacts_by_id = account.contacts.where(id: contact_ids).index_by(&:id)
    ignored_pairs = load_ignored_conflict_pairs(contact_ids)
    open_conflicts = load_open_conflicts_by_pair(contact_ids)
    counts = preload_relation_counts(contact_ids)

    build_duplicate_items(pairs, contacts_by_id, ignored_pairs, open_conflicts, counts)
  end

  def dismiss!(contact_id:, duplicate_contact_id:, user: nil)
    first = account.contacts.find(contact_id)
    second = account.contacts.find(duplicate_contact_id)
    raise ArgumentError, 'Cannot dismiss the same contact' if first.id == second.id

    Contact.transaction do
      record_dismissed_id!(first, second.id)
      record_dismissed_id!(second, first.id)
      ignore_open_conflicts!(first.id, second.id, user)
    end
  end

  def self.resolve_open_conflicts!(account:, base_contact_id:, mergee_contact_id:, user: nil)
    ids = [base_contact_id.to_s, mergee_contact_id.to_s]
    Integrations::Medelement::SyncConflict
      .where(account_id: account.id, status: 'open')
      .where("details ->> 'contact_id' IN (:ids) OR details ->> 'conflicting_contact_id' IN (:ids)", ids: ids)
      .find_each do |conflict|
        c_ids = [conflict.details['contact_id'].to_s, conflict.details['conflicting_contact_id'].to_s].compact_blank
        next unless (c_ids - ids).empty?

        conflict.update!(
          status: 'resolved',
          resolved_by: user,
          resolved_at: Time.current,
          resolution_note: "Contacts merged into ##{base_contact_id}"
        )
      end
  end

  private

  attr_reader :account

  def collect_candidate_pairs
    raw_pairs = Set.new
    add_group_pairs(raw_pairs, iin_candidate_groups)
    add_direct_pairs(raw_pairs, conflict_and_shared_phone_pairs)
    add_group_pairs(raw_pairs, full_name_candidate_groups)
    raw_pairs.to_a.first(MAX_PAIRS * 3)
  end

  def add_group_pairs(set, groups)
    groups.each do |ids|
      next if ids.size < 2 || ids.size > MAX_NAME_GROUP_SIZE

      ids.sort.combination(2) { |pair| set.add(pair) }
    end
  end

  def add_direct_pairs(set, pairs)
    pairs.each do |first_id, second_id|
      next if first_id.blank? || second_id.blank? || first_id == second_id

      set.add([first_id, second_id].sort)
    end
  end

  def iin_candidate_groups
    account.contacts
           .where("#{IIN_SQL_EXPR} IS NOT NULL")
           .group(Arel.sql(IIN_SQL_EXPR))
           .having('COUNT(*) > 1')
           .limit(MAX_PAIRS)
           .pluck(Arel.sql('ARRAY_AGG(id ORDER BY id)'))
  end

  def conflict_and_shared_phone_pairs
    open_conflict_pairs + shared_phone_owner_pairs + secondary_phone_owner_pairs
  end

  def open_conflict_pairs
    Integrations::Medelement::SyncConflict
      .where(account_id: account.id, status: 'open', conflict_type: 'phone_owned_by_another_contact')
      .limit(MAX_PAIRS * 2)
      .pluck(Arel.sql("(details ->> 'contact_id')::int"), Arel.sql("(details ->> 'conflicting_contact_id')::int"))
      .select { |c_id, conf_id| c_id.present? && conf_id.present? }
  end

  def shared_phone_owner_pairs
    account.contacts
           .where("custom_attributes ? 'medelement_shared_phone_owner_id'")
           .limit(MAX_PAIRS * 2)
           .pluck(:id, Arel.sql("(custom_attributes ->> 'medelement_shared_phone_owner_id')::int"))
           .select { |c_id, owner_id| c_id.present? && owner_id.present? }
  end

  def secondary_phone_owner_pairs
    query = ActiveRecord::Base.sanitize_sql_array(
      [SECONDARY_PHONE_OWNER_SQL, { account_id: account.id, limit: MAX_PAIRS * 2 }]
    )
    ActiveRecord::Base.connection.select_rows(query)
  end

  def full_name_candidate_groups
    account.contacts
           .where("LENGTH(#{FIRST_NAME_SQL_EXPR}) >= 2 AND LENGTH(#{LAST_NAME_SQL_EXPR}) >= 2")
           .group(Arel.sql("LEAST(#{FIRST_NAME_SQL_EXPR}, #{LAST_NAME_SQL_EXPR}), GREATEST(#{FIRST_NAME_SQL_EXPR}, #{LAST_NAME_SQL_EXPR})"))
           .having('COUNT(*) BETWEEN 2 AND ?', MAX_NAME_GROUP_SIZE)
           .limit(MAX_PAIRS)
           .pluck(Arel.sql('ARRAY_AGG(id ORDER BY id)'))
  end

  def build_duplicate_items(pairs, contacts_by_id, ignored_pairs, open_conflicts, counts)
    items = []
    pairs.each do |first_id, second_id|
      item = build_pair_item(contacts_by_id[first_id], contacts_by_id[second_id], ignored_pairs, open_conflicts, counts)
      next unless item

      items << item
      break if items.size >= MAX_PAIRS
    end
    items
  end

  def build_pair_item(first, second, ignored_pairs, open_conflicts, counts)
    return unless valid_duplicate_pair?(first, second, ignored_pairs)

    primary, conflicting = order_pair(first, second, counts)
    pair_key = [first.id, second.id].sort
    reasons = match_reasons_for(primary, conflicting, open_conflicts[pair_key])
    return if reasons.empty?

    {
      id: "#{primary.id}:#{conflicting.id}",
      match_reasons: reasons,
      conflict_id: open_conflicts[pair_key],
      primary_contact: serialize_contact(primary, counts),
      conflicting_contact: serialize_contact(conflicting, counts)
    }
  end

  def valid_duplicate_pair?(first, second, ignored_pairs)
    return false if first.blank? || second.blank?
    return false if ignored_pairs.include?([first.id, second.id].sort)
    return false if dismissed_in_attributes?(first, second.id) || dismissed_in_attributes?(second, first.id)
    return false unless Contacts::PatientIdentityMergeGuard.same_person_cards?(first, second)

    Contacts::PatientIdentityMergeGuard.explicit_merge_allowed?(base_contact: first, mergee_contact: second)
  end

  def dismissed_in_attributes?(contact, other_id)
    Array(contact.custom_attributes.to_h[DISMISSED_KEY]).map(&:to_i).include?(other_id.to_i)
  end

  def order_pair(first, second, counts)
    first_score = contact_priority_score(first, counts)
    second_score = contact_priority_score(second, counts)
    return [second, first] if second_score > first_score

    [first, second]
  end

  def contact_priority_score(contact, counts)
    phone_score = contact.phone_number.present? ? 1000 : 0
    activity_score = %i[conversations appointments deals calls].sum { |k| counts[k][contact.id].to_i }
    phone_score + activity_score
  end

  def match_reasons_for(first, second, conflict_id)
    reasons = []
    reasons << 'same_iin' if same_iin?(first, second)
    reasons << 'shared_phone' if conflict_id.present? || shares_phone?(first, second)
    reasons << 'same_full_name' if same_full_name?(first, second)
    reasons << 'same_birth_date' if same_birth_date?(first, second)
    reasons
  end

  def same_iin?(first, second)
    first_iin = extract_iin(first)
    first_iin.present? && first_iin == extract_iin(second)
  end

  def same_birth_date?(first, second)
    first_dob = birth_date_for(first)
    first_dob.present? && first_dob == birth_date_for(second)
  end

  def shares_phone?(first, second)
    return true if all_phones_for(first).intersect?(all_phones_for(second))

    shared_key = Integrations::Medelement::PatientContactBinding::SHARED_OWNER_KEY
    first_owner = first.custom_attributes.to_h[shared_key]&.to_i
    second_owner = second.custom_attributes.to_h[shared_key]&.to_i
    first_owner == second.id || second_owner == first.id
  end

  def all_phones_for(contact)
    attrs = contact.custom_attributes.to_h
    raw = [
      contact.phone_number,
      attrs[Contacts::SharedPhone::MEDELEMENT_PHONE_KEY],
      *Array(attrs['secondary_phones'])
    ]
    raw.filter_map { |p| Integrations::Medelement::PhoneNumber.normalize(p) }.uniq
  end

  def same_full_name?(first, second)
    first_parts = extract_names(first)
    second_parts = extract_names(second)
    return false if first_parts.any?(&:blank?) || second_parts.any?(&:blank?)

    first_parts.sort == second_parts.sort
  end

  def extract_names(contact)
    attrs = contact.custom_attributes.to_h
    first = attrs['medelement_first_name'].presence || contact.name.to_s.strip.presence
    last = attrs['medelement_last_name'].presence || contact.last_name.to_s.strip.presence
    if last.blank? && first.present?
      tokens = first.split(/\s+/).compact_blank
      return tokens.map { |t| normalized_name(t) } if tokens.size == 2
    end
    [normalized_name(first), normalized_name(last)]
  end

  def normalized_name(value)
    value.to_s.unicode_normalize(:nfkc).downcase.tr('ё', 'е').squish.presence
  end

  def extract_iin(contact)
    attrs = contact.custom_attributes.to_h
    raw = attrs['iin'].presence || attrs['medelement_iin'].presence || contact.identifier
    Scheduling::IinValidator.normalize(raw) if Scheduling::IinValidator.valid?(raw)
  end

  def birth_date_for(contact)
    attrs = contact.custom_attributes.to_h
    attrs['birth_date'].presence || attrs['medelement_birth_date'].presence
  end

  def serialize_contact(contact, counts)
    attrs = contact.custom_attributes.to_h
    {
      id: contact.id,
      name: full_display_name(contact),
      first_name: contact.name,
      last_name: contact.last_name,
      middle_name: contact.middle_name,
      email: contact.email,
      phone_number: contact.phone_number,
      secondary_phones: Array(attrs['secondary_phones']).compact_blank.first(10),
      identifier_masked: mask_identifier(extract_iin(contact)),
      birth_date: birth_date_for(contact),
      patient_code: attrs['medelement_patient_code'],
      last_activity_at: contact.last_activity_at&.iso8601
    }.merge(contact_relation_counts(contact.id, counts))
  end

  def full_display_name(contact)
    [contact.name, contact.last_name, contact.middle_name].compact_blank.join(' ').presence || contact.name
  end

  def contact_relation_counts(contact_id, counts)
    {
      conversations_count: counts[:conversations][contact_id].to_i,
      appointments_count: counts[:appointments][contact_id].to_i,
      deals_count: counts[:deals][contact_id].to_i,
      call_sessions_count: counts[:calls][contact_id].to_i
    }
  end

  def mask_identifier(identifier)
    value = identifier.to_s
    return if value.blank?
    return value if value.length <= 4

    "#{'*' * (value.length - 4)}#{value.last(4)}"
  end

  def preload_relation_counts(contact_ids)
    {
      conversations: Conversation.where(account_id: account.id, contact_id: contact_ids).group(:contact_id).count,
      appointments: Scheduling::Appointment.where(account_id: account.id, contact_id: contact_ids).group(:contact_id).count,
      deals: Crm::DealContact.where(account_id: account.id, contact_id: contact_ids).group(:contact_id).distinct.count(:deal_id),
      calls: Telephony::CallSession.where(account_id: account.id, contact_id: contact_ids).group(:contact_id).count
    }
  end

  def load_ignored_conflict_pairs(contact_ids)
    ids_str = contact_ids.map(&:to_s)
    Integrations::Medelement::SyncConflict
      .where(account_id: account.id, status: 'ignored')
      .where("details ->> 'contact_id' IN (:ids) OR details ->> 'conflicting_contact_id' IN (:ids)", ids: ids_str)
      .each_with_object(Set.new) do |conflict, set|
        c1 = conflict.details['contact_id']&.to_i
        c2 = conflict.details['conflicting_contact_id']&.to_i
        set.add([c1, c2].sort) if c1.present? && c2.present?
      end
  end

  def load_open_conflicts_by_pair(contact_ids)
    ids_str = contact_ids.map(&:to_s)
    Integrations::Medelement::SyncConflict
      .where(account_id: account.id, status: 'open', conflict_type: 'phone_owned_by_another_contact')
      .where("details ->> 'contact_id' IN (:ids) OR details ->> 'conflicting_contact_id' IN (:ids)", ids: ids_str)
      .each_with_object({}) do |conflict, map|
        c1 = conflict.details['contact_id']&.to_i
        c2 = conflict.details['conflicting_contact_id']&.to_i
        map[[c1, c2].sort] = conflict.id if c1.present? && c2.present?
      end
  end

  def record_dismissed_id!(contact, other_id)
    attrs = contact.custom_attributes.to_h.deep_stringify_keys
    dismissed = (Array(attrs[DISMISSED_KEY]).map(&:to_i) + [other_id.to_i]).uniq
    attrs[DISMISSED_KEY] = dismissed
    contact.skip_runtime_events = true
    contact.update!(custom_attributes: attrs)
  end

  def ignore_open_conflicts!(first_id, second_id, user)
    ids = [first_id.to_s, second_id.to_s]
    Integrations::Medelement::SyncConflict
      .where(account_id: account.id, status: 'open')
      .where("details ->> 'contact_id' IN (:ids) OR details ->> 'conflicting_contact_id' IN (:ids)", ids: ids)
      .find_each do |conflict|
        c_ids = [conflict.details['contact_id'].to_s, conflict.details['conflicting_contact_id'].to_s].compact_blank
        next unless (c_ids - ids).empty?

        conflict.ignore!(user: user, note: 'Marked as separate contacts')
      end
  end
end
# rubocop:enable Metrics/ClassLength
