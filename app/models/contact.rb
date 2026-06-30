# rubocop:disable Layout/LineLength

# == Schema Information
#
# Table name: contacts
#
#  id                    :integer          not null, primary key
#  additional_attributes :jsonb
#  blocked               :boolean          default(FALSE), not null
#  contact_type          :integer          default("visitor")
#  country_code          :string           default("")
#  custom_attributes     :jsonb
#  email                 :string
#  identifier            :string
#  last_activity_at      :datetime
#  last_name             :string           default("")
#  location              :string           default("")
#  middle_name           :string           default("")
#  name                  :string           default("")
#  phone_number          :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :integer          not null
#  company_id            :bigint
#  owner_id              :bigint
#
# Indexes
#
#  idx_contacts_account_medelement_patient_code          (account_id, ((custom_attributes ->> 'medelement_patient_code'::text))) UNIQUE WHERE ((custom_attributes ->> 'medelement_patient_code'::text) IS NOT NULL)
#  index_contacts_on_account_id                          (account_id)
#  index_contacts_on_account_id_and_contact_type         (account_id,contact_type)
#  index_contacts_on_account_id_and_last_activity_at     (account_id,last_activity_at DESC NULLS LAST)
#  index_contacts_on_blocked                             (blocked)
#  index_contacts_on_company_id                          (company_id)
#  index_contacts_on_lower_email_account_id              (lower((email)::text), account_id)
#  index_contacts_on_name_email_phone_number_identifier  (name,email,phone_number,identifier) USING gin
#  index_contacts_on_nonempty_fields                     (account_id,email,phone_number,identifier) WHERE (((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text))
#  index_contacts_on_owner_id                            (owner_id)
#  index_contacts_on_phone_number_and_account_id         (phone_number,account_id)
#  index_resolved_contact_account_id                     (account_id) WHERE (((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text))
#  uniq_email_per_account_contact                        (email,account_id) UNIQUE
#  uniq_identifier_per_account_contact                   (identifier,account_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (owner_id => users.id)
#

# rubocop:enable Layout/LineLength

class Contact < ApplicationRecord
  DISPLAY_PREFERENCES_KEY = 'display_preferences'.freeze
  PRIMARY_NAME_SOURCE_KEY = 'primary_name_source'.freeze
  PRIMARY_AVATAR_SOURCE_KEY = 'primary_avatar_source'.freeze
  DISPLAY_SOURCE_KIND_MANUAL = 'manual'.freeze
  DISPLAY_SOURCE_KIND_CONTACT_AVATAR = 'contact_avatar'.freeze
  DISPLAY_SOURCE_KIND_CHANNEL_PROFILE = 'channel_profile'.freeze

  include Avatarable
  include AvailabilityStatusable
  include Labelable
  include LlmFormattable

  attr_accessor :skip_runtime_events

  validates :account_id, presence: true
  validates :email, allow_blank: true, uniqueness: { scope: [:account_id], case_sensitive: false },
                    format: { with: Devise.email_regexp, message: I18n.t('errors.contacts.email.invalid') }
  validates :identifier, allow_blank: true, uniqueness: { scope: [:account_id] }
  validates :phone_number,
            allow_blank: true, uniqueness: { scope: [:account_id] },
            format: { with: /\+[1-9]\d{1,14}\z/, message: I18n.t('errors.contacts.phone_number.invalid') }
  validate :owner_belongs_to_account

  belongs_to :account
  belongs_to :owner, class_name: 'User', optional: true
  has_many :campaign_deliveries, dependent: :delete_all
  has_many :communication_threads, dependent: :destroy
  has_many :conversations, dependent: :destroy_async
  has_many :contact_inboxes, dependent: :destroy_async
  has_many :contact_channel_profiles, dependent: :destroy
  has_many :crm_deal_contacts, class_name: 'Crm::DealContact', dependent: :destroy_async
  has_many :crm_deals, through: :crm_deal_contacts, source: :deal
  has_many :csat_survey_responses, dependent: :destroy_async
  has_many :inboxes, through: :contact_inboxes
  has_many :messages, as: :sender, dependent: :destroy_async
  has_many :meta_ad_referrals, dependent: :nullify
  has_many :notes, dependent: :destroy_async
  has_many :scheduling_appointments, dependent: :nullify, class_name: 'Scheduling::Appointment'
  before_validation :prepare_contact_attributes, :normalize_phone_number
  before_save :sync_contact_attributes
  after_commit :sync_unified_owner, if: :saved_change_to_owner_id?
  after_create_commit :dispatch_create_event, :ip_lookup
  after_update_commit :dispatch_update_event
  after_destroy_commit :dispatch_destroy_event

  enum contact_type: { visitor: 0, lead: 1, customer: 2 }

  scope :order_on_last_activity_at, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order("\"contacts\".\"last_activity_at\" #{direction}
          NULLS LAST")
      )
    )
  }
  scope :order_on_created_at, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order("\"contacts\".\"created_at\" #{direction}
          NULLS LAST")
      )
    )
  }
  scope :order_on_company_name, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "\"contacts\".\"additional_attributes\"->>'company_name' #{direction}
          NULLS LAST"
        )
      )
    )
  }
  scope :order_on_city, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "\"contacts\".\"additional_attributes\"->>'city' #{direction}
          NULLS LAST"
        )
      )
    )
  }
  scope :order_on_country_name, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "\"contacts\".\"additional_attributes\"->>'country' #{direction}
          NULLS LAST"
        )
      )
    )
  }

  scope :order_on_name, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "CASE
           WHEN \"contacts\".\"name\" ~~* '^+\d*' THEN 'z'
           WHEN \"contacts\".\"name\"  ~~*  '^\b*' THEN 'z'
           ELSE LOWER(\"contacts\".\"name\")
           END #{direction}"
        )
      )
    )
  }

  # Find contacts that:
  # 1. Have no identification (email, phone_number, and identifier are NULL or empty string)
  # 2. Have no conversations
  # 3. Are older than the specified time period
  scope :stale_without_conversations, lambda { |time_period|
    where('contacts.email IS NULL OR contacts.email = ?', '')
      .where('contacts.phone_number IS NULL OR contacts.phone_number = ?', '')
      .where('contacts.identifier IS NULL OR contacts.identifier = ?', '')
      .where('contacts.created_at < ?', time_period)
      .where.missing(:conversations)
  }

  def get_source_id(inbox_id)
    contact_inboxes.find_by!(inbox_id: inbox_id).source_id
  end

  def push_event_data(contact_inbox: nil)
    data = {
      additional_attributes: additional_attributes,
      custom_attributes: custom_attributes,
      email: email,
      id: id,
      identifier: identifier,
      name: name,
      owner_id: owner_id,
      owner: owner&.push_event_data,
      phone_number: phone_number,
      thumbnail: resolved_avatar_url,
      blocked: blocked,
      type: 'contact'
    }

    apply_channel_profile_data(data, contact_inbox)
  end

  def webhook_data
    {
      account: account.webhook_data,
      additional_attributes: additional_attributes,
      avatar: resolved_avatar_url,
      custom_attributes: custom_attributes,
      email: email,
      id: id,
      identifier: identifier,
      name: name,
      owner_id: owner_id,
      owner: owner&.webhook_data,
      phone_number: phone_number,
      thumbnail: resolved_avatar_url,
      blocked: blocked
    }
  end

  def self.resolved_contacts(use_crm_v2: false)
    return where(contact_type: 'lead') if use_crm_v2

    where(contact_type: [:lead, :customer])
      .or(where("contacts.email <> '' OR contacts.phone_number <> '' OR contacts.identifier <> ''"))
  end

  def display_preferences
    (additional_attributes || {}).with_indifferent_access[DISPLAY_PREFERENCES_KEY].to_h.deep_stringify_keys
  end

  def primary_name_source
    display_preferences[PRIMARY_NAME_SOURCE_KEY].to_h.deep_stringify_keys
  end

  def primary_avatar_source
    display_preferences[PRIMARY_AVATAR_SOURCE_KEY].to_h.deep_stringify_keys
  end

  def resolved_primary_name_source
    resolve_display_source(primary_name_source) || inferred_primary_name_source
  end

  def resolved_primary_avatar_source
    resolve_display_source(primary_avatar_source) || inferred_primary_avatar_source
  end

  def display_source_for_contact_inbox(contact_inbox, kind: DISPLAY_SOURCE_KIND_CHANNEL_PROFILE)
    return if contact_inbox.blank?

    profile = channel_profile_for(contact_inbox)
    {
      'kind' => kind,
      'contact_inbox_id' => contact_inbox.id,
      'inbox_id' => contact_inbox.inbox_id,
      'channel_type' => contact_inbox.inbox&.channel_type,
      'provider' => profile&.provider.presence || contact_inbox.inbox&.channel_type.to_s.demodulize.underscore,
      'source_id' => contact_inbox.source_id,
      'identifier' => profile&.identifier
    }.compact
  end

  def merge_display_source(additional_attributes:, key:, source:)
    attrs = (additional_attributes || {}).deep_stringify_keys
    next_source = source.to_h.deep_stringify_keys
    return attrs if next_source.blank?

    prefs = (attrs[DISPLAY_PREFERENCES_KEY] || {}).deep_stringify_keys
    attrs.merge(DISPLAY_PREFERENCES_KEY => prefs.merge(key => next_source))
  end

  def name_updates_allowed_for?(contact_inbox:, replaceable_current_name:)
    return true if replaceable_current_name

    source = resolve_display_source(primary_name_source)
    return display_source_matches_contact_inbox?(source, contact_inbox) if source.present?

    false
  end

  def avatar_updates_allowed_for?(contact_inbox:)
    source = resolve_display_source(primary_avatar_source)
    return display_source_matches_contact_inbox?(source, contact_inbox) if source.present?

    !linked_to_other_channel_type?(contact_inbox)
  end

  def resolved_avatar_url
    explicit_source = resolve_display_source(primary_avatar_source)
    explicit_avatar = avatar_url_from_source(explicit_source)
    return explicit_avatar if explicit_avatar.present?

    current_avatar = attached_avatar_url
    return current_avatar if current_avatar.present?

    name_avatar = avatar_url_from_source(resolve_display_source(primary_name_source))
    return name_avatar if name_avatar.present?

    fallback_avatar = latest_avatar_profile&.avatar_url.to_s
    return fallback_avatar if fallback_avatar.present?

    ''
  end

  def contact_avatar_url
    attached_avatar_url
  end

  def discard_invalid_attrs
    phone_number_format
    email_format
  end

  def self.from_email(email)
    find_by(email: email&.downcase)
  end

  private

  def apply_channel_profile_data(data, contact_inbox)
    profile = channel_profile_for(contact_inbox)
    return data if profile.blank?

    data[:channel_profile] = profile.push_event_data
    data[:name] = profile.display_name if profile.display_name.present?
    data[:thumbnail] = profile.avatar_url if profile.avatar_url.present?
    data
  end

  def channel_profile_for(contact_inbox)
    return if contact_inbox.blank?

    if contact_inbox.association(:channel_profile).loaded?
      profile = contact_inbox.channel_profile
      return profile if profile.present?
    end

    contact_channel_profiles.find_by(contact_inbox_id: contact_inbox.id)
  end

  def ip_lookup
    return if runtime_events_suppressed?
    return unless account.feature_enabled?('ip_lookup')

    ContactIpLookupJob.perform_later(self)
  end

  def phone_number_format
    return if phone_number.blank?

    self.phone_number = phone_number_was unless phone_number.match?(/\+[1-9]\d{1,14}\z/)
  end

  def email_format
    return if email.blank?

    self.email = email_was unless email.match(Devise.email_regexp)
  end

  def prepare_contact_attributes
    prepare_email_attribute
    prepare_jsonb_attributes
  end

  def normalize_phone_number
    return self.phone_number = nil if phone_number.blank?

    normalized_phone_number = ::Contacts::PhoneNumberNormalizer.normalize(
      phone_number,
      default_country: phone_number_default_country
    )
    self.phone_number = normalized_phone_number if normalized_phone_number.present?
  end

  def prepare_email_attribute
    # So that the db unique constraint won't throw error when email is ''
    self.email = email.present? ? email.downcase : nil
  end

  def prepare_jsonb_attributes
    self.additional_attributes = {} if additional_attributes.blank?
    self.custom_attributes = {} if custom_attributes.blank?
  end

  def phone_number_default_country
    additional_attributes_country_code =
      additional_attributes.with_indifferent_access[:country_code].presence
    legacy_country_code = additional_attributes.with_indifferent_access[:country].to_s
    legacy_country_code = nil unless legacy_country_code.match?(/\A[a-z]{2}\z/i)

    country_code.presence || additional_attributes_country_code || legacy_country_code
  end

  def resolve_display_source(source)
    candidate = source.to_h.deep_stringify_keys
    return if candidate.blank?

    kind = candidate['kind'].to_s
    return candidate if kind == DISPLAY_SOURCE_KIND_MANUAL
    return candidate if kind == DISPLAY_SOURCE_KIND_CONTACT_AVATAR && attached_avatar_url.present?
    return candidate if kind == DISPLAY_SOURCE_KIND_CHANNEL_PROFILE && channel_profile_for_display_source(candidate).present?

    nil
  end

  def inferred_primary_name_source
    normalized_name = name.to_s.strip
    return if normalized_name.blank?

    profile = sorted_channel_profiles.find do |channel_profile|
      channel_profile.display_name.to_s.strip == normalized_name
    end

    display_source_for_channel_profile(profile)
  end

  def inferred_primary_avatar_source
    return({ 'kind' => DISPLAY_SOURCE_KIND_CONTACT_AVATAR }) if attached_avatar_url.present?

    profile = latest_avatar_profile
    display_source_for_channel_profile(profile)
  end

  def avatar_url_from_source(source)
    return '' if source.blank?

    case source['kind']
    when DISPLAY_SOURCE_KIND_CONTACT_AVATAR
      attached_avatar_url
    when DISPLAY_SOURCE_KIND_CHANNEL_PROFILE
      channel_profile_for_display_source(source)&.avatar_url.to_s
    else
      ''
    end
  end

  def attached_avatar_url
    return '' unless avatar.attached? && avatar.representable?

    url_for(avatar.representation(resize_to_fill: [250, nil]))
  end

  def latest_avatar_profile
    sorted_channel_profiles.find { |profile| profile.avatar_url.present? }
  end

  def sorted_channel_profiles
    @sorted_channel_profiles ||= contact_channel_profiles.to_a.sort_by do |profile|
      [profile.last_synced_at || profile.updated_at || Time.zone.at(0), profile.id]
    end.reverse
  end

  def display_source_for_channel_profile(profile)
    return if profile.blank?

    {
      'kind' => DISPLAY_SOURCE_KIND_CHANNEL_PROFILE,
      'contact_inbox_id' => profile.contact_inbox_id,
      'inbox_id' => profile.inbox_id,
      'channel_type' => profile.channel_type,
      'provider' => profile.provider,
      'source_id' => profile.source_id,
      'identifier' => profile.identifier
    }.compact
  end

  def channel_profile_for_display_source(source)
    return if source.blank?

    source = source.to_h.deep_stringify_keys
    return unless source['kind'] == DISPLAY_SOURCE_KIND_CHANNEL_PROFILE

    return contact_channel_profiles.find_by(contact_inbox_id: source['contact_inbox_id']) if source['contact_inbox_id'].present?

    if source['identifier'].present?
      profile = contact_channel_profiles.find_by(identifier: source['identifier'])
      return profile if profile.present?
    end

    return if source['source_id'].blank?

    scope = contact_channel_profiles.where(source_id: source['source_id'])
    scope = scope.where(provider: source['provider']) if source['provider'].present?
    scope.order(last_synced_at: :desc, updated_at: :desc, id: :desc).first
  end

  def display_source_matches_contact_inbox?(source, contact_inbox)
    return false if source.blank? || contact_inbox.blank?
    return false unless source['kind'] == DISPLAY_SOURCE_KIND_CHANNEL_PROFILE

    return source['contact_inbox_id'].to_s == contact_inbox.id.to_s if source['contact_inbox_id'].present?

    source['source_id'].to_s == contact_inbox.source_id.to_s &&
      source['inbox_id'].to_s == contact_inbox.inbox_id.to_s
  end

  def linked_to_other_channel_type?(contact_inbox)
    return false if contact_inbox.blank?

    contact_inboxes.joins(:inbox).where.not(inboxes: { channel_type: contact_inbox.inbox.channel_type }).exists?
  end

  def sync_contact_attributes
    ::Contacts::SyncAttributes.new(self).perform
  end

  def sync_unified_owner
    return if destroyed?

    ::Contacts::OwnerSyncService.new(contact: self).perform
  end

  def owner_belongs_to_account
    return if owner_id.blank?
    return if account&.users&.exists?(id: owner_id)

    errors.add(:owner_id, 'must belong to the current account')
  end

  def dispatch_create_event
    return if runtime_events_suppressed?

    Rails.configuration.dispatcher.dispatch(CONTACT_CREATED, Time.zone.now, contact: self)
  end

  def dispatch_update_event
    return if runtime_events_suppressed?

    Rails.configuration.dispatcher.dispatch(CONTACT_UPDATED, Time.zone.now, contact: self, changed_attributes: previous_changes)
  end

  def dispatch_destroy_event
    # Pass serialized data instead of ActiveRecord object to avoid DeserializationError
    # when the async EventDispatcherJob runs after the contact has been deleted
    Rails.configuration.dispatcher.dispatch(
      CONTACT_DELETED,
      Time.zone.now,
      contact_data: push_event_data.merge(account_id: account_id)
    )
  end

  def runtime_events_suppressed?
    skip_runtime_events || Current.suppress_runtime_events
  end
end
Contact.include_mod_with('Concerns::Contact')
