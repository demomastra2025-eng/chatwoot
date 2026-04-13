class TelegramPersonal::ContactSyncService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if peer_user_id.blank?

    @contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: peer_user_id.to_s,
      contact_attributes: contact_attributes,
      skip_runtime_events: true
    ).perform

    @contact = @contact_inbox.contact
    sync_existing_contact!
    sync_channel_profile!
    sync_avatar!
    @contact_inbox.reload
  end

  private

  def contact_attributes
    {
      name: display_name,
      phone_number: safe_phone_number,
      identifier: contact_identifier,
      additional_attributes: additional_attributes,
      avatar_url: safe_avatar_url
    }.compact
  end

  def sync_existing_contact!
    current_attributes = (@contact.additional_attributes || {}).deep_stringify_keys
    merged_attributes = merged_additional_attributes(current_attributes)
    @avatar_refresh_required = should_refresh_contact_avatar?(current_attributes)

    updates = {}
    updates[:additional_attributes] = merged_attributes if merged_attributes != current_attributes
    updates[:identifier] = contact_identifier if should_update_contact_identifier?
    updates[:phone_number] = normalized_phone_number if @contact.phone_number.blank? && normalized_phone_number.present?
    updates[:name] = display_name if should_replace_contact_name?(@contact)

    if latest_activity_at.present? && (@contact.last_activity_at.blank? || latest_activity_at > @contact.last_activity_at)
      updates[:last_activity_at] = latest_activity_at
    end

    return if updates.blank?

    @contact.skip_runtime_events = true
    @contact.update!(updates)
  rescue ActiveRecord::RecordInvalid => e
    raise unless phone_number_conflict?(e, updates)

    merge_phone_contact!
    @contact.reload
    @contact_inbox.reload
    remove_instance_variable(:@telegram_primary_contact) if instance_variable_defined?(:@telegram_primary_contact)
    retry
  end

  def sync_avatar!
    return unless @avatar_refresh_required

    Avatar::AvatarFromUrlJob.perform_later(@contact, avatar_url)
  rescue StandardError => e
    Rails.logger.info("[TELEGRAM PERSONAL] Avatar sync enqueue failed for contact #{@contact.id}: #{e.class}: #{e.message}")
  end

  def sync_channel_profile!
    profile_data = telegram_channel_profile
    profile = Contacts::ChannelProfileUpsertService.new(
      contact_inbox: @contact_inbox,
      provider: 'telegram_personal',
      profile_attributes: profile_data.merge(
        display_name: channel_profile_display_name,
        avatar_url: safe_avatar_url,
        phone_number: channel_profile_phone_number,
        profile_data: profile_data
      )
    ).perform
    repair_self_profile_channel_profile!(profile)
  end

  def display_name
    [
      (@contact&.name if self_profile_payload?),
      [safe_first_name, safe_last_name].compact.join(' ').strip.presence,
      safe_username,
      safe_phone_number,
      peer_user_id.to_s
    ].compact.first.to_s.truncate(100)
  end

  def additional_attributes
    {
      provider: 'telegram_personal',
      social_telegram_user_id: social_telegram_user_id,
      social_telegram_user_name: safe_username,
      username: safe_username,
      language_code: params[:language_code],
      first_name: safe_first_name,
      last_name: safe_last_name,
      phone_number: safe_phone_number,
      profile_photo_url: safe_avatar_url,
      is_bot: boolean_value(:is_bot),
      is_contact: boolean_value(:is_contact),
      is_mutual_contact: boolean_value(:is_mutual_contact),
      is_premium: boolean_value(:is_premium),
      is_verified: boolean_value(:is_verified),
      is_scam: boolean_value(:is_scam),
      is_fake: boolean_value(:is_fake),
      is_restricted: boolean_value(:is_restricted),
      is_deleted: boolean_value(:is_deleted),
      sync_source: sync_source,
      last_message_at: latest_activity_at&.iso8601,
      unread_count: unread_count
    }.compact
  end

  def merged_additional_attributes(current_attributes)
    merged_attributes = current_attributes.deep_dup
    merged_attributes.merge!(telegram_shared_additional_attributes)
    merged_attributes.merge!(additional_attributes.deep_stringify_keys) if telegram_primary_contact? && !self_profile_payload?
    merged_attributes['channel_profiles'] = merged_channel_profiles(current_attributes)
    merged_attributes
  end

  def merged_channel_profiles(current_attributes)
    channel_profiles = (current_attributes['channel_profiles'] || {}).deep_stringify_keys
    telegram_profiles = (channel_profiles['telegram_personal'] || {}).deep_stringify_keys
    telegram_profiles[contact_identifier] = telegram_channel_profile
    channel_profiles.merge('telegram_personal' => telegram_profiles)
  end

  def telegram_shared_additional_attributes
    {
      social_telegram_user_id: social_telegram_user_id,
      social_telegram_user_name: safe_username
    }.compact.deep_stringify_keys
  end

  def telegram_channel_profile
    {
      identifier: contact_identifier,
      source_id: peer_user_id.to_s,
      inbox_id: inbox.id,
      peer_user_id: social_telegram_user_id,
      username: safe_username,
      language_code: params[:language_code],
      first_name: safe_first_name,
      last_name: safe_last_name,
      phone_number: safe_phone_number,
      profile_photo_url: safe_avatar_url,
      is_bot: boolean_value(:is_bot),
      is_contact: boolean_value(:is_contact),
      is_mutual_contact: boolean_value(:is_mutual_contact),
      is_premium: boolean_value(:is_premium),
      is_verified: boolean_value(:is_verified),
      is_scam: boolean_value(:is_scam),
      is_fake: boolean_value(:is_fake),
      is_restricted: boolean_value(:is_restricted),
      is_deleted: boolean_value(:is_deleted),
      sync_source: sync_source,
      last_message_at: latest_activity_at&.iso8601,
      unread_count: unread_count
    }.compact.deep_stringify_keys
  end

  def should_refresh_contact_avatar?(current_attributes)
    return false if safe_avatar_url.blank?
    return false unless telegram_primary_contact?
    return true unless @contact.avatar.attached?

    current_attributes['profile_photo_url'] != safe_avatar_url
  end

  def should_update_contact_identifier?
    @contact.identifier.blank? && contact_identifier.present? && telegram_primary_contact?
  end

  def telegram_primary_contact?
    return @telegram_primary_contact if defined?(@telegram_primary_contact)

    claimed_by_other_identifier = @contact.identifier.present? && @contact.identifier != contact_identifier
    claimed_by_other_provider = current_provider.present? && current_provider != 'telegram_personal'
    linked_to_other_provider = @contact.contact_inboxes.joins(:inbox).where.not(inboxes: { channel_type: 'Channel::TelegramPersonal' }).exists?

    @telegram_primary_contact = !(claimed_by_other_identifier || claimed_by_other_provider || linked_to_other_provider)
  end

  def current_provider
    (@contact.additional_attributes || {}).with_indifferent_access[:provider].presence
  end

  def phone_number_conflict?(error, updates)
    updates[:phone_number].present? && error.record.errors.of_kind?(:phone_number, :taken)
  end

  def merge_phone_contact!
    target_contact = inbox.account.contacts.find_by(phone_number: normalized_phone_number)
    return if target_contact.blank? || target_contact.id == @contact.id

    ActiveRecord::Base.transaction do
      merge_contact_records!(source_contact: @contact, target_contact: target_contact)
    end

    @contact = target_contact
  end

  def merge_contact_records!(source_contact:, target_contact:)
    now = Time.current

    source_contact.contact_inboxes.update_all(contact_id: target_contact.id, updated_at: now)
    ContactChannelProfile.where(contact_id: source_contact.id).update_all(contact_id: target_contact.id, updated_at: now)
    Conversation.where(contact_id: source_contact.id).update_all(contact_id: target_contact.id, updated_at: now)
    Message.where(sender_type: 'Contact', sender_id: source_contact.id).update_all(sender_id: target_contact.id, updated_at: now)

    {
      'Note' => :contact_id,
      'CampaignDelivery' => :contact_id,
      'CsatSurveyResponse' => :contact_id,
      'Scheduling::Appointment' => :contact_id
    }.each do |class_name, foreign_key|
      klass = class_name.safe_constantize
      next if klass.blank?

      klass.where(foreign_key => source_contact.id).update_all(foreign_key => target_contact.id, updated_at: now)
    end

    source_attributes = (source_contact.additional_attributes || {}).deep_stringify_keys
    target_attributes = (target_contact.additional_attributes || {}).deep_stringify_keys
    merged_additional_attributes = source_attributes.merge(target_attributes)

    merged_channel_profiles = (source_attributes['channel_profiles'] || {}).deep_stringify_keys
      .merge((target_attributes['channel_profiles'] || {}).deep_stringify_keys) do |_key, old_value, new_value|
        old_hash = old_value.is_a?(Hash) ? old_value.deep_stringify_keys : {}
        new_hash = new_value.is_a?(Hash) ? new_value.deep_stringify_keys : {}
        old_hash.merge(new_hash)
      end
    merged_additional_attributes['channel_profiles'] = merged_channel_profiles if merged_channel_profiles.present?

    source_contact.update_columns(identifier: nil, updated_at: now) if source_contact.identifier.present?

    target_contact.skip_runtime_events = true
    target_contact.update!(
      additional_attributes: merged_additional_attributes,
      name: preferred_contact_name(target_contact, source_contact),
      phone_number: target_contact.phone_number.presence || source_contact.phone_number,
      identifier: target_contact.identifier.presence || source_contact.identifier
    )

    source_contact.skip_runtime_events = true
    source_contact.destroy!
  rescue ActiveRecord::RecordNotDestroyed
    source_contact.update_columns(identifier: nil, updated_at: now) if source_contact.identifier.present?
  end

  def preferred_contact_name(target_contact, source_contact)
    return display_name if should_replace_contact_name?(target_contact)
    return source_contact.name if target_contact.name.blank? && source_contact.name.present?

    target_contact.name
  end

  def should_replace_contact_name?(contact)
    return false if display_name.blank?
    return false if self_profile_payload?
    return true if contact.name.blank?
    return true if contact.name == contact.phone_number

    normalized_name = contact.name.to_s.strip
    identity_aliases.include?(normalized_name)
  end

  def identity_aliases
    @identity_aliases ||= [
      peer_user_id.to_s,
      normalized_phone_number,
      contact_identifier,
      params[:username].presence,
      username_handle
    ].compact.uniq
  end

  def username_handle
    username = params[:username].to_s.strip
    return if username.blank?

    "@#{username}"
  end

  def contact_identifier
    "telegram_personal:#{peer_user_id}"
  end

  def avatar_url
    params[:avatar_url].presence
  end

  def safe_first_name
    return if self_profile_payload?

    params[:first_name].presence
  end

  def safe_last_name
    return if self_profile_payload?

    params[:last_name].presence
  end

  def safe_username
    return if self_profile_payload?

    params[:username].presence
  end

  def safe_phone_number
    return if self_profile_payload?

    normalized_phone_number
  end

  def safe_avatar_url
    return if self_profile_payload?

    avatar_url
  end

  def channel_profile_display_name
    return @contact&.name.presence || display_name if self_profile_payload?

    display_name
  end

  def channel_profile_phone_number
    return @contact&.phone_number.presence if self_profile_payload?

    safe_phone_number
  end

  def normalized_phone_number
    return @normalized_phone_number if defined?(@normalized_phone_number)

    raw_value = params[:phone_number].to_s.strip
    candidate = raw_value.presence
    candidate = "+#{candidate}" if candidate.present? && !candidate.start_with?('+')

    @normalized_phone_number = Contacts::PhoneNumberNormalizer.normalize(candidate)
  end

  def peer_user_id
    params[:peer_user_id] || params[:sender_id] || params[:chat_id]
  end

  def self_profile_payload?
    return @self_profile_payload if defined?(@self_profile_payload)

    @self_profile_payload = sync_source.in?(%w[message_event activity_event]) &&
      normalized_phone_number.present? &&
      channel_phone_number.present? &&
      normalized_phone_number == channel_phone_number
  end

  def channel_phone_number
    return @channel_phone_number if defined?(@channel_phone_number)

    @channel_phone_number = Contacts::PhoneNumberNormalizer.normalize(inbox.channel.phone_number)
  end

  def repair_self_profile_channel_profile!(profile)
    return unless self_profile_payload?
    return if profile.blank?

    cleaned_profile_data = (profile.profile_data || {}).deep_stringify_keys.except(
      'avatar_url',
      'display_name',
      'first_name',
      'last_name',
      'name',
      'phone_number',
      'profile_photo_url',
      'username'
    )

    profile.update!(
      display_name: channel_profile_display_name,
      avatar_url: nil,
      username: nil,
      phone_number: channel_profile_phone_number,
      profile_data: cleaned_profile_data
    )
  end

  def social_telegram_user_id
    value = peer_user_id.to_s
    value.match?(/\A\d+\z/) ? value.to_i : value
  end

  def sync_source
    params[:sync_source].presence || (params[:activity_type].present? ? 'activity_event' : 'message_event')
  end

  def unread_count
    return unless params.key?(:unread_count)

    params[:unread_count].to_i
  end

  def boolean_value(key)
    return unless params.key?(key)

    ActiveModel::Type::Boolean.new.cast(params[key])
  end

  def latest_activity_at
    return @latest_activity_at if defined?(@latest_activity_at)

    raw_value = params[:last_message_at].presence || params[:message_created_at].presence || params[:external_created_at].presence
    @latest_activity_at = raw_value.present? ? Time.zone.parse(raw_value.to_s) : nil
  rescue ArgumentError
    @latest_activity_at = nil
  end
end
