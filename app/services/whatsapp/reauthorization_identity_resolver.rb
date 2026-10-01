require 'digest'

# The immutable proof object is specific to this resolver.
# Resolves a reauthorization target from the fresh token issued by Meta. This is
# deliberately separate from the initial-signup WABA resolver: an existing
# channel may only move to assets that prove the same physical phone and owner.
class Whatsapp::ReauthorizationIdentityResolver
  REQUIRED_SCOPES = %w[whatsapp_business_management whatsapp_business_messaging].freeze
  META_ID_FORMAT = /\A\d{1,32}\z/
  MAX_GRANTED_WABAS = 10
  MAX_PHONE_PAGES_PER_WABA = 10
  MAX_PHONE_RECORDS_PER_WABA = 1_000

  class ResolutionError < ArgumentError
    attr_reader :error_code

    def initialize(error_code, message = 'Unable to verify the existing WhatsApp connection')
      @error_code = error_code
      super(message)
    end
  end

  class Resolution # rubocop:disable Style/OneClassPerFile
    IDENTITY_KEYS = %w[business_account_id phone_number_id business_id source embedded_signup_flow].freeze

    attr_reader :account_id, :inbox_id, :channel_id, :old_identity, :target_identity,
                :phone_number, :physical_phone, :owner_business_id, :access_token_fingerprint

    # Keep the proof's full binding explicit at construction.
    # rubocop:disable Metrics/ParameterLists
    def initialize(account_id:, inbox_id:, channel_id:, old_identity:, target_identity:, phone_number:,
                   physical_phone:, owner_business_id:, access_token:)
      @account_id = account_id.to_s
      @inbox_id = inbox_id.to_s
      @channel_id = channel_id.to_s
      @old_identity = normalize_identity(old_identity).freeze
      @target_identity = normalize_identity(target_identity).freeze
      @phone_number = phone_number.to_s
      @physical_phone = physical_phone.to_s
      @owner_business_id = owner_business_id.to_s.presence
      @access_token_fingerprint = Digest::SHA256.hexdigest(access_token.to_s)
      freeze
    end
    # rubocop:enable Metrics/ParameterLists

    def identity_changed?
      %w[business_account_id phone_number_id].any? do |key|
        old_identity[key].to_s != target_identity[key].to_s
      end
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity
    def valid_for?(account_id:, inbox_id:, channel:, current_identity:, target_identity:, signup_type:, access_token:,
                   phone_info:)
      return false unless account_id.to_s == @account_id && inbox_id.to_s == @inbox_id
      return false unless channel.id.to_s == @channel_id && channel.account_id.to_s == @account_id
      return false unless channel.provider == 'whatsapp_cloud'
      return false unless normalize_identity(current_identity) == @old_identity
      return false unless normalize_identity(target_identity) == @target_identity
      return false unless signup_type.to_s == @target_identity['embedded_signup_flow'].to_s
      return false unless Digest::SHA256.hexdigest(access_token.to_s) == @access_token_fingerprint
      return false unless normalize_phone(channel.phone_number) == @physical_phone
      return false unless normalize_phone(phone_info[:phone_number]) == @physical_phone
      return false unless phone_info[:phone_number_id].to_s == @target_identity['phone_number_id'].to_s

      return true unless identity_changed?

      @owner_business_id.present? &&
        @owner_business_id == @old_identity['business_id'] &&
        @owner_business_id == @target_identity['business_id']
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity

    private

    def normalize_identity(identity)
      identity.to_h.stringify_keys.slice(*IDENTITY_KEYS).transform_values { |value| value.presence&.to_s }
    end

    def normalize_phone(value)
      Whatsapp::ReauthorizationIdentityResolver.normalize_phone(value)
    end
  end

  def self.normalize_phone(value)
    value = value.to_s.strip
    return if value.blank? || !value.match?(/\A\+?[\d\s().-]+\z/)

    value.gsub(/\D/, '').presence
  end

  # The proof is bound to the request and selected Meta target; keep the binding explicit.
  # rubocop:disable Metrics/ParameterLists
  def initialize(access_token:, account_id:, inbox_id:, channel_id:, old_identity:, phone_number:, signup_type:,
                 requested_waba_id: nil, requested_phone_number_id: nil, requested_business_id: nil, api_client: nil)
    @access_token = access_token
    @account_id = account_id
    @inbox_id = inbox_id
    @channel_id = channel_id
    @old_identity = old_identity.to_h.stringify_keys
    @phone_number = phone_number
    @signup_type = signup_type.to_s
    @requested_waba_id = requested_waba_id.presence
    @requested_phone_number_id = requested_phone_number_id.presence
    @requested_business_id = requested_business_id.presence
    @api_client = api_client || Whatsapp::FacebookApiClient.new(access_token)
  end
  # rubocop:enable Metrics/ParameterLists

  # This method coordinates bounded grants, phone ownership, and identity proof.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def perform
    expected_phone = self.class.normalize_phone(@phone_number)
    raise ResolutionError, 'unverifiable_phone' if expected_phone.blank?

    validate_requested_business!
    waba_ids = granted_waba_ids
    candidate_waba_ids = requested_waba_candidates(waba_ids)
    matches = candidate_waba_ids.flat_map { |waba_id| physical_phone_matches(waba_id, expected_phone) }
    raise ResolutionError, 'asset_not_found' if matches.empty?
    raise ResolutionError, 'asset_ambiguous' if matches.many?

    match = matches.first
    validate_requested_phone!(match)
    validate_coexistence_phone!(match[:phone_data]) if @signup_type == 'coexistence'

    current_identity = normalized_old_identity
    target_business_id = current_identity['business_id']
    owner_business_id = nil
    if identity_changed?(current_identity, match)
      raise ResolutionError, 'business_identity_unavailable' if current_identity['business_id'].blank?
      raise ResolutionError, 'signup_identity_unavailable' unless current_identity['source'] == 'embedded_signup'
      raise ResolutionError, 'signup_identity_unavailable' unless current_identity['embedded_signup_flow'].to_s == @signup_type
      raise ResolutionError, 'app_identity_unavailable' if @expected_app_id.blank?

      owner_business_id = fetch_owner_business_id(match[:waba_id])
      raise ResolutionError, 'business_identity_mismatch' unless owner_business_matches?(owner_business_id, current_identity)

      target_business_id = owner_business_id
    end

    Resolution.new(
      account_id: @account_id,
      inbox_id: @inbox_id,
      channel_id: @channel_id,
      old_identity: current_identity,
      target_identity: {
        'business_account_id' => match[:waba_id],
        'phone_number_id' => match[:phone_data]['id'],
        'business_id' => target_business_id,
        'source' => current_identity['source'],
        'embedded_signup_flow' => @signup_type
      },
      phone_number: @phone_number,
      physical_phone: expected_phone,
      owner_business_id: owner_business_id,
      access_token: @access_token
    )
  rescue ResolutionError
    raise
  rescue StandardError
    raise ResolutionError, 'asset_lookup_failed'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  private

  def owner_business_matches?(owner_business_id, current_identity)
    owner_business_id.present? && owner_business_id == current_identity['business_id']
  end

  def validate_requested_business!
    persisted = normalized_old_identity['business_id']
    return if @requested_business_id.blank? || @requested_business_id.to_s == persisted.to_s

    raise ResolutionError, 'business_selection_mismatch'
  end

  # Scope intersection is intentionally explicit; malformed grants must fail closed.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def granted_waba_ids
    response = @api_client.debug_token(@access_token)
    data = response['data'].to_h
    raise ResolutionError, 'invalid_access_token' unless ActiveModel::Type::Boolean.new.cast(data['is_valid'])

    @expected_app_id = GlobalConfigService.load('WHATSAPP_APP_ID', '').to_s
    @token_app_id = data['app_id'].to_s
    raise ResolutionError, 'app_identity_mismatch' if @expected_app_id.present? && @token_app_id != @expected_app_id

    global_scopes = Array(data['scopes']).map(&:to_s)
    granular_scopes = Array(data['granular_scopes']).grep(Hash)
    scoped_targets = REQUIRED_SCOPES.filter_map do |required_scope|
      rows = granular_scopes.select { |scope| scope['scope'].to_s == required_scope }
      if rows.present?
        raw_ids = rows.flat_map do |scope|
          target_ids = scope['target_ids']
          raise ResolutionError, 'grant_targets_incomplete' unless target_ids.is_a?(Array) && target_ids.present?

          target_ids.map(&:to_s)
        end
        raise ResolutionError, 'grant_targets_incomplete' unless raw_ids.all? { |id| META_ID_FORMAT.match?(id) }

        raw_ids.uniq
      else
        # A named scope is global only when Meta supplied no granular row for
        # that permission. An empty row is incomplete evidence, not a wildcard.
        next if global_scopes.include?(required_scope)

        raise ResolutionError, 'required_asset_grants_missing'
      end
    end
    raise ResolutionError, 'grant_targets_unavailable' if scoped_targets.empty?

    granted = scoped_targets.reduce { |intersection, ids| intersection & ids }
    raise ResolutionError, 'required_asset_grants_missing' if granted.blank?
    raise ResolutionError, 'asset_limit_exceeded' if granted.size > MAX_GRANTED_WABAS

    granted
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def requested_waba_candidates(granted_waba_ids)
    return granted_waba_ids if @requested_waba_id.blank?
    raise ResolutionError, 'business_asset_selection_invalid' unless META_ID_FORMAT.match?(@requested_waba_id.to_s)
    raise ResolutionError, 'business_asset_selection_mismatch' unless granted_waba_ids.include?(@requested_waba_id.to_s)

    [@requested_waba_id.to_s]
  end

  # Pagination and record limits are part of the identity safety boundary.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def physical_phone_matches(waba_id, expected_phone)
    matches = []
    after = nil
    pages = 0
    records = 0

    loop do
      pages += 1
      raise ResolutionError, 'asset_page_limit_exceeded' if pages > MAX_PHONE_PAGES_PER_WABA

      response = @api_client.fetch_phone_numbers(
        waba_id,
        after: after,
        fields: Whatsapp::PhoneInfoService::PHONE_NUMBER_FIELDS
      )
      data = response['data']
      raise ResolutionError, 'asset_page_unreadable' unless data.is_a?(Array)

      records += data.size
      raise ResolutionError, 'asset_record_limit_exceeded' if records > MAX_PHONE_RECORDS_PER_WABA

      raise ResolutionError, 'asset_page_unreadable' unless data.all?(Hash)

      data.each do |phone_data|
        display_phone = self.class.normalize_phone(phone_data['display_phone_number'])
        raise ResolutionError, 'asset_page_unreadable' if display_phone.blank?
        next unless display_phone == expected_phone
        raise ResolutionError, 'asset_page_unreadable' unless META_ID_FORMAT.match?(phone_data['id'].to_s)

        matches << { waba_id: waba_id, phone_data: phone_data }
      end

      break if response.dig('paging', 'next').blank?

      after = response.dig('paging', 'cursors', 'after')
      raise ResolutionError, 'asset_page_unreadable' if after.blank?
    end

    matches
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def validate_requested_phone!(match)
    return if @requested_phone_number_id.blank?
    return if match[:phone_data]['id'].to_s == @requested_phone_number_id.to_s

    raise ResolutionError, 'phone_asset_selection_mismatch'
  end

  def validate_coexistence_phone!(phone_data)
    on_business_app = ActiveModel::Type::Boolean.new.cast(phone_data['is_on_biz_app'])
    return if on_business_app && phone_data['platform_type'].to_s == 'CLOUD_API'

    raise ResolutionError, 'coexistence_identity_mismatch'
  end

  def fetch_owner_business_id(waba_id)
    response = @api_client.fetch_waba_info(waba_id, fields: %w[owner_business_info])
    response.dig('owner_business_info', 'id').to_s.presence
  end

  def normalized_old_identity
    Resolution::IDENTITY_KEYS.index_with do |key|
      @old_identity[key].presence&.to_s
    end
  end

  def identity_changed?(current_identity, match)
    current_identity['business_account_id'].to_s != match[:waba_id].to_s ||
      current_identity['phone_number_id'].to_s != match[:phone_data]['id'].to_s
  end
end
