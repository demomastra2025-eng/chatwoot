# frozen_string_literal: true

class Telephony::Wazo::ProvisioningService # rubocop:disable Metrics/ClassLength -- complete managed Wazo resource graph lifecycle
  ENDPOINT_LABEL_PREFIX = 'OneLink managed'
  REMOTE_REF_KEYS = %w[wazo_user_uuid wazo_line_id wazo_extension_id wazo_endpoint_uuid].freeze
  REMOTE_LOCK_TTL = 30.minutes

  def initialize(account:, inbox:, client: Telephony::Wazo::ApiClient.new, sip_context: ENV.fetch('TELEPHONY_WAZO_SIP_CONTEXT', nil))
    @account = account
    @inbox = inbox
    @client = client
    @sip_context = sip_context.to_s.strip
    return if @sip_context.present?

    raise Telephony::Error.new(
      code: 'WAZO_SIP_CONTEXT_NOT_CONFIGURED',
      message: 'Wazo SIP context is not configured',
      status: :service_unavailable
    )
  end

  def sync!
    with_remote_lock do
      desired = desired_profiles.index_by { |profile| endpoint_name(profile) }
      existing = managed_endpoints.index_by { |endpoint| endpoint.fetch('name') }
      actual_names = existing.keys
      operations = desired.map do |name, profile|
        renew_remote_lock!
        sync_profile_graph!(name, profile, existing.delete(name))
      end
      operations.concat(existing.values.map { |endpoint| retained_stale_graph_operation(endpoint) })

      sync_result(desired.keys, actual_names | desired.keys, operations)
    end
  end

  def reconcile
    desired_by_name = desired_profiles.index_by { |profile| endpoint_name(profile) }
    desired_names = desired_by_name.keys.sort
    endpoints = managed_endpoints
    actual_names = endpoints.filter_map { |endpoint| endpoint['name'] }.sort
    incomplete = endpoints.filter_map do |endpoint|
      name = endpoint['name']
      profile = desired_by_name[name]
      name if profile.present? && !graph_complete?(endpoint, profile)
    end.sort

    reconciliation_payload(desired_names, actual_names, incomplete)
  end

  def delete_all!
    with_remote_lock do
      operations = profiles_with_remote_refs.map do |profile|
        renew_remote_lock!
        cleanup_profile_graph!(profile)
      end

      {
        status: 'remote_committed', remote_commit: true, executed_operations: operations,
        remote_snapshot: { endpoint_names: [] }
      }
    end
  end

  private

  attr_reader :account, :inbox, :client, :sip_context

  def with_remote_lock
    lock_manager = Redis::LockManager.new
    acquired = lock_manager.lock(remote_lock_key, REMOTE_LOCK_TTL)
    unless acquired
      raise Telephony::Error.new(
        code: 'WAZO_PROVISIONING_IN_PROGRESS',
        message: 'Another Wazo provisioning operation is already running',
        status: :conflict
      )
    end

    @remote_lock_manager = lock_manager
    yield
  ensure
    @remote_lock_manager = nil
    lock_manager&.unlock(remote_lock_key) if acquired
  end

  def remote_lock_key
    "onelink:wazo:provisioning:account:#{account.id}:inbox:#{inbox.id}"
  end

  def renew_remote_lock!
    return true if @remote_lock_manager&.renew(remote_lock_key, REMOTE_LOCK_TTL)

    raise Telephony::Error.new(
      code: 'WAZO_PROVISIONING_LOCK_LOST',
      message: 'Wazo provisioning lock was lost before the operation completed',
      status: :conflict
    )
  end

  def desired_profiles
    inbox.telephony_sip_profiles.where(status: 'active', enabled: true).select do |profile|
      profile.sip_username.present? && profile.sip_password.present? && profile.internal_extension.present?
    end
  end

  def profiles_with_remote_refs
    inbox.telephony_sip_profiles.to_a.select do |profile|
      REMOTE_REF_KEYS.any? { |key| profile.metadata.to_h[key].present? }
    end
  end

  def managed_endpoints
    client.sip_endpoints.select do |endpoint|
      endpoint['name'].to_s.start_with?(endpoint_prefix) && endpoint['label'].to_s == endpoint_label
    end
  end

  def sync_profile_graph!(name, profile, endpoint)
    created = {}
    remote_refs = resolve_graph_resources!(profile, endpoint, created)
    user_uuid, line_id, extension_id, endpoint_uuid = remote_refs.values_at(:user_uuid, :line_id, :extension_id, :endpoint_uuid)
    associate_graph!(user_uuid, line_id, extension_id, endpoint_uuid)
    persist_remote_refs!(profile, name, remote_refs)

    graph_operation(created, name, remote_refs)
  rescue StandardError
    rollback_errors = rollback_created!(created || {})
    clear_created_remote_refs!(profile, created || {}) if rollback_errors.empty?
    raise
  end

  def resolve_graph_resources!(profile, endpoint, created) # rubocop:disable Metrics/AbcSize -- ordered remote-resource checkpoint saga
    refs = validated_persisted_refs(profile, endpoint)
    graph = existing_graph_refs(endpoint, profile)
    remote_refs = {}
    remote_refs[:user_uuid], created[:user] = upsert_user!(profile, refs['wazo_user_uuid'] || graph[:user_uuid])
    checkpoint_remote_ref!(profile, 'wazo_user_uuid', remote_refs[:user_uuid])
    remote_refs[:endpoint_uuid], created[:endpoint] = upsert_endpoint!(profile, endpoint)
    checkpoint_remote_ref!(profile, 'wazo_endpoint_uuid', remote_refs[:endpoint_uuid])
    line_result = upsert_line_and_extension!(
      profile,
      refs['wazo_line_id'] || graph[:line_id],
      refs['wazo_extension_id'] || graph[:extension_id]
    )
    remote_refs[:line_id], remote_refs[:extension_id], created[:line], created[:extension] = line_result
    checkpoint_remote_ref!(profile, 'wazo_line_id', remote_refs[:line_id])
    checkpoint_remote_ref!(profile, 'wazo_extension_id', remote_refs[:extension_id])
    remote_refs
  end

  def validated_persisted_refs(profile, discovered_endpoint)
    refs = profile.metadata.to_h.stringify_keys.slice(*REMOTE_REF_KEYS)
    return refs if refs.values.none?(&:present?)
    return validated_partial_refs(profile, refs) unless REMOTE_REF_KEYS.all? { |key| refs[key].present? }

    endpoint_uuid = refs.fetch('wazo_endpoint_uuid')
    endpoint = if discovered_endpoint&.fetch('uuid', nil).to_s == endpoint_uuid.to_s
                 discovered_endpoint
               else
                 client.sip_endpoint(endpoint_uuid)
               end
    actual = graph_refs(endpoint, profile: profile)
    ensure_cleanup_refs_match!(refs, actual)
    refs
  end

  def validated_partial_refs(profile, refs)
    verified = refs.each_with_object({}) do |(key, identifier), result|
      next if identifier.blank?

      result[key] = identifier if persisted_ref_owned?(profile, key, identifier, refs)
    rescue Telephony::Error => e
      raise unless not_found?(e)

      clear_checkpoint_remote_ref!(profile, key)
    end
    validate_line_only_extension_checkpoint!(profile, refs, verified)
    verified
  end

  def validate_line_only_extension_checkpoint!(profile, refs, verified)
    return if refs['wazo_line_id'].blank? || refs['wazo_extension_id'].present?

    line = client.line(refs['wazo_line_id'])
    extension_summary = managed_extension_for_profile(line, profile)
    raise_extension_recovery_error! if extension_summary.blank?

    extension = client.extension(extension_summary.fetch('id'))
    raise_extension_recovery_error! unless extension_belongs_solely_to_line?(extension, line)

    verified['wazo_extension_id'] = extension.fetch('id')
  rescue KeyError
    raise_extension_recovery_error!
  end

  def persisted_ref_owned?(profile, key, identifier, refs)
    resource, expected = persisted_ref_resource_and_marker(profile, key, identifier)
    raise_cleanup_refs_error! unless expected.all? { |field, value| resource[field].to_s == value.to_s }
    ensure_extension_belongs_to_line!(resource, refs['wazo_line_id']) if key == 'wazo_extension_id'

    true
  end

  def ensure_extension_belongs_to_line!(extension, line_id)
    raise_cleanup_refs_error! if line_id.blank?

    line = client.line(line_id)
    raise_cleanup_refs_error! unless extension_belongs_solely_to_line?(extension, line)
  end

  def extension_belongs_solely_to_line?(extension, line)
    extension_ids = Array(line['extensions']).filter_map { |candidate| candidate['id'] }
    extension_ids.map(&:to_s).include?(extension['id'].to_s) && sole_line?(extension, line)
  end

  def persisted_ref_resource_and_marker(profile, key, identifier)
    case key
    when 'wazo_user_uuid'
      [client.user(identifier), user_payload(profile).stringify_keys.slice('username', 'lastname')]
    when 'wazo_line_id'
      [client.line(identifier), line_payload(profile).stringify_keys.slice('context', 'caller_id_name')]
    when 'wazo_extension_id'
      [client.extension(identifier), extension_payload(profile).stringify_keys]
    when 'wazo_endpoint_uuid'
      [client.sip_endpoint(identifier), { 'name' => endpoint_name(profile), 'label' => endpoint_label }]
    else
      raise_cleanup_refs_error!
    end
  end

  def clear_checkpoint_remote_ref!(profile, key)
    profile.update!(metadata: profile.metadata.to_h.except(key))
  end

  def existing_graph_refs(endpoint, profile)
    endpoint.present? ? graph_refs(endpoint, profile: profile, require_complete_ownership: false) : {}
  end

  def upsert_user!(profile, user_uuid)
    payload = user_payload(profile)
    user_uuid ||= matching_user_uuid(payload)
    return create_resource!(:create_user, payload, 'uuid') if user_uuid.blank?

    client.update_user(user_uuid, payload)
    [user_uuid, nil]
  rescue Telephony::Error => e
    raise unless not_found?(e)

    create_resource!(:create_user, payload, 'uuid')
  end

  def matching_user_uuid(payload)
    client.users.find do |user|
      user['username'].to_s == payload[:username] && user['lastname'].to_s == payload[:lastname]
    end&.fetch('uuid', nil)
  end

  def upsert_line_and_extension!(profile, line_id, extension_id)
    line_id ||= matching_line_id(profile)
    return create_line_with_extension!(profile) if line_id.blank?

    line = client.line(line_id)
    extension_id ||= managed_extension_for_profile(line, profile)&.fetch('id', nil)
    raise_extension_recovery_error! if extension_id.blank?

    extension = client.extension(extension_id)
    raise_extension_recovery_error! unless extension_belongs_solely_to_line?(extension, line)

    client.update_line(line_id, line_payload(profile))
    client.update_extension(extension_id, extension_payload(profile))
    [line_id, extension_id, nil, nil]
  end

  def matching_line_id(profile)
    client.lines.find { |line| line['caller_id_name'].to_s == line_marker(profile.id) }&.fetch('id', nil)
  end

  def create_line_with_extension!(profile)
    conflicting = client.extensions.any? do |extension|
      extension['context'].to_s == sip_context && extension['exten'].to_s == profile.internal_extension.to_s
    end
    raise_extension_recovery_error! if conflicting

    remote = client.create_line(line_payload(profile).merge(extensions: [extension_payload(profile)]))
    line_id = remote['id'].presence
    extension_id = managed_extension_for_profile(remote, profile)&.fetch('id', nil)
    raise_extension_recovery_error! if line_id.blank? || extension_id.blank?

    [line_id, extension_id, line_id, extension_id]
  end

  def extension_payload(profile)
    { context: sip_context, exten: profile.internal_extension }
  end

  def managed_extension_for_profile(line, profile)
    Array.wrap(line['extensions']).find do |extension|
      extension['context'].to_s == sip_context && extension['exten'].to_s == profile.internal_extension.to_s
    end
  end

  def raise_extension_recovery_error!
    raise Telephony::Error.new(
      code: 'WAZO_EXTENSION_OWNERSHIP_UNPROVEN',
      message: 'Wazo extension ownership could not be proven; provisioning was blocked',
      status: :conflict
    )
  end

  def upsert_endpoint!(profile, endpoint)
    payload = endpoint_payload(profile)
    return create_resource!(:create_sip_endpoint, payload, 'uuid') if endpoint.blank?

    uuid = endpoint.fetch('uuid')
    remote = client.update_sip_endpoint(uuid, payload)
    [remote['uuid'].presence || uuid, nil]
  end

  def create_resource!(method, payload, id_key)
    remote = client.public_send(method, payload)
    identifier = remote[id_key].presence
    return [identifier, identifier] if identifier.present?

    raise Telephony::Error.new(
      code: 'WAZO_RESOURCE_ID_MISSING',
      message: "Wazo #{method} response did not include #{id_key}",
      status: :bad_gateway
    )
  end

  def associate_graph!(user_uuid, line_id, extension_id, endpoint_uuid)
    client.associate_user_line(user_uuid, line_id)
    client.associate_line_extension(line_id, extension_id)
    client.associate_line_sip_endpoint(line_id, endpoint_uuid)
  end

  def rollback_created!(created)
    rollback_errors = []
    created_refs = {
      user_uuid: created[:user], line_id: created[:line],
      extension_id: created[:extension], endpoint_uuid: created[:endpoint]
    }
    rollback_step(rollback_errors) { dissociate_graph!(created_refs) } if created[:line].present?
    rollback_actions(created).each do |action, identifier|
      rollback_step(rollback_errors) { client.public_send(action, identifier) }
    end
    return rollback_errors if rollback_errors.empty?

    Rails.logger.error("Wazo provisioning rollback failed: #{rollback_errors.map { |error| error.class.name }.uniq.join(',')}")
    rollback_errors
  end

  def clear_created_remote_refs!(profile, created)
    key_by_resource = {
      user: 'wazo_user_uuid', line: 'wazo_line_id',
      extension: 'wazo_extension_id', endpoint: 'wazo_endpoint_uuid'
    }
    keys = created.filter_map { |resource, identifier| key_by_resource[resource] if identifier.present? }
    return if keys.empty?

    profile.update!(metadata: profile.metadata.to_h.except(*keys))
  end

  def rollback_step(errors)
    yield
  rescue StandardError => e
    errors << e
  end

  def rollback_actions(created)
    {
      delete_sip_endpoint: created[:endpoint], delete_extension: created[:extension],
      delete_line: created[:line], delete_user: created[:user]
    }.compact
  end

  def cleanup_profile_graph!(profile)
    metadata_refs = cleanup_metadata_refs(profile)
    endpoint = client.sip_endpoint(metadata_refs.fetch('wazo_endpoint_uuid'))
    refs = graph_refs(endpoint, profile: profile)
    ensure_cleanup_refs_match!(metadata_refs, refs)
    dissociate_graph!(refs)
    delete_graph_resources!(refs)

    operation('delete_graph', endpoint.fetch('name'), refs)
  end

  def cleanup_metadata_refs(profile)
    refs = profile.metadata.to_h.stringify_keys.slice(
      'wazo_endpoint_uuid', 'wazo_line_id', 'wazo_extension_id', 'wazo_user_uuid'
    )
    raise_cleanup_refs_error! unless refs.values.all?(&:present?)

    refs
  end

  def ensure_cleanup_refs_match!(metadata_refs, refs)
    expected = metadata_refs.values_at('wazo_endpoint_uuid', 'wazo_line_id', 'wazo_extension_id', 'wazo_user_uuid')
    actual = refs.values_at(:endpoint_uuid, :line_id, :extension_id, :user_uuid)
    raise_cleanup_refs_error! unless ActiveSupport::SecurityUtils.secure_compare(expected.map(&:to_s).join(':'), actual.map(&:to_s).join(':'))
  end

  def delete_graph_resources!(refs)
    client.delete_sip_endpoint(refs[:endpoint_uuid])
    client.delete_extension(refs[:extension_id])
    client.delete_line(refs[:line_id])
    client.delete_user(refs[:user_uuid])
  end

  def retained_stale_graph_operation(endpoint)
    operation('retain_stale_graph', endpoint.fetch('name'), endpoint_uuid: endpoint.fetch('uuid'))
  end

  def raise_cleanup_refs_error!
    raise Telephony::Error.new(
      code: 'WAZO_GRAPH_OWNERSHIP_UNPROVEN',
      message: 'Wazo resource graph does not match persisted ownership references; cleanup was blocked',
      status: :conflict
    )
  end

  def graph_refs(endpoint, profile:, require_complete_ownership: true)
    endpoint = client.sip_endpoint(endpoint.fetch('uuid')) if endpoint.dig('line', 'id').blank?
    line_id = endpoint.dig('line', 'id')
    line = line_id.present? ? client.line(line_id) : {}
    ensure_owned_graph!(endpoint, line, profile, require_complete: require_complete_ownership)
    {
      endpoint_uuid: endpoint.fetch('uuid'),
      line_id: line_id,
      extension_id: managed_extension_for_profile(line, profile)&.fetch('id', nil),
      user_uuid: managed_user_for_profile(line, profile)&.fetch('uuid', nil)
    }
  end

  def ensure_owned_graph!(endpoint, line, profile, require_complete:)
    return if owned_graph?(endpoint, line, profile, require_complete: require_complete)

    raise Telephony::Error.new(
      code: 'WAZO_GRAPH_OWNERSHIP_UNPROVEN',
      message: 'Wazo resource graph ownership could not be proven; cleanup was blocked',
      status: :conflict
    )
  end

  def owned_graph?(endpoint, line, profile, require_complete:)
    return false unless endpoint['name'].to_s == endpoint_name(profile) && owned_endpoint?(endpoint)
    return !require_complete if line.blank?

    users = Array.wrap(line['users'])
    extensions = Array.wrap(line['extensions'])
    complete = users.one? && extensions.one?
    (!require_complete || complete) && owned_graph_relations?(endpoint, line, users, extensions, profile)
  end

  def owned_graph_relations?(endpoint, line, users, extensions, profile)
    owned_line?(line, endpoint, profile.id) && owned_users?(users, line, profile) &&
      owned_extensions?(extensions, line, profile)
  end

  def owned_endpoint?(endpoint)
    endpoint['name'].to_s.start_with?(endpoint_prefix) && endpoint['label'].to_s == endpoint_label
  end

  def owned_line?(line, endpoint, profile_id)
    line['caller_id_name'].to_s == line_marker(profile_id) && line.dig('endpoint_sip', 'uuid').to_s == endpoint['uuid'].to_s
  end

  def owned_users?(users, line, profile)
    users.all? do |user|
      remote = client.user(user.fetch('uuid'))
      expected = user_payload(profile)
      remote['username'].to_s == expected[:username] && remote['lastname'].to_s == expected[:lastname] && sole_line?(remote, line)
    end
  end

  def owned_extensions?(extensions, line, profile)
    extensions.all? do |extension|
      remote = client.extension(extension.fetch('id'))
      expected = extension_payload(profile)
      remote['context'].to_s == expected[:context] && remote['exten'].to_s == expected[:exten].to_s && sole_line?(remote, line)
    end
  end

  def sole_line?(resource, line)
    Array.wrap(resource['lines']).map { |item| item['id'].to_s } == [line['id'].to_s]
  end

  def managed_user_for_profile(line, profile)
    expected = user_payload(profile)
    Array.wrap(line['users']).find do |candidate|
      candidate['username'].to_s == expected[:username] || candidate['lastname'].to_s == expected[:lastname]
    end
  end

  def dissociate_graph!(refs)
    line_id = refs[:line_id]
    return if line_id.blank?

    client.dissociate_line_sip_endpoint(line_id, refs[:endpoint_uuid])
    client.dissociate_line_extension(line_id, refs[:extension_id]) if refs[:extension_id].present?
    client.dissociate_user_line(refs[:user_uuid], line_id) if refs[:user_uuid].present?
  end

  def graph_complete?(endpoint, profile)
    refs = graph_refs(endpoint, profile: profile)
    refs.values.all?(&:present?)
  rescue Telephony::Error
    false
  end

  def user_payload(profile)
    {
      firstname: profile.user&.name.presence || 'OneLink operator',
      lastname: "managed #{account.id}/#{inbox.id}/#{profile.id}",
      username: "#{user_prefix}p#{profile.id}"
    }
  end

  def line_payload(profile)
    { context: sip_context, caller_id_name: line_marker(profile.id) }
  end

  def line_marker(profile_id)
    "OneLink managed a=#{account.id} i=#{inbox.id} p=#{profile_id}"
  end

  def endpoint_payload(profile)
    {
      name: endpoint_name(profile), label: endpoint_label,
      aor_section_options: [%w[max_contacts 5], %w[remove_existing yes], %w[qualify_frequency 30]],
      auth_section_options: [['username', profile.sip_username], ['password', profile.sip_password]],
      endpoint_section_options: [
        ['context', sip_context], ['disallow', 'all'], ['allow', 'opus,alaw,ulaw'],
        ['direct_media', 'no'], ['force_rport', 'yes'], ['rewrite_contact', 'yes'], ['rtp_symmetric', 'yes']
      ]
    }
  end

  def persist_remote_refs!(profile, name, refs)
    metadata = profile.metadata.to_h.merge(
      'wazo_endpoint_name' => name,
      'wazo_endpoint_uuid' => refs[:endpoint_uuid],
      'wazo_user_uuid' => refs[:user_uuid],
      'wazo_line_id' => refs[:line_id],
      'wazo_extension_id' => refs[:extension_id],
      'wazo_synced_at' => Time.current.iso8601
    ).compact
    profile.update!(metadata: metadata)
  end

  def checkpoint_remote_ref!(profile, key, value)
    return if value.blank? || profile.metadata.to_h[key].to_s == value.to_s

    profile.update!(metadata: profile.metadata.to_h.merge(key => value))
  end

  def graph_operation(created, name, refs)
    action = created.values.any?(&:present?) ? 'create_graph' : 'update_graph'
    operation(action, name, refs)
  end

  def sync_result(desired_names, actual_names, operations)
    {
      status: 'remote_committed', remote_commit: true, executed_operations: operations,
      reconciliation: reconciliation_payload(desired_names, actual_names, []),
      remote_snapshot: { endpoint_names: actual_names.sort }
    }
  end

  def reconciliation_payload(desired_names, actual_names, incomplete_names)
    missing = desired_names - actual_names
    stale = actual_names - desired_names
    {
      status: missing.empty? && stale.empty? && incomplete_names.empty? ? 'ready' : 'drifted',
      desired_endpoint_count: desired_names.size,
      actual_endpoint_count: actual_names.size,
      missing_endpoint_names: missing,
      stale_endpoint_names: stale,
      incomplete_graph_endpoint_names: incomplete_names,
      checked_at: Time.current.iso8601
    }
  end

  def endpoint_name(profile)
    "#{endpoint_prefix}p#{profile.id}"
  end

  def endpoint_prefix
    "ol-a#{account.id}-i#{inbox.id}-"
  end

  def user_prefix
    "#{endpoint_prefix}u-"
  end

  def user_lastname_prefix
    "managed #{account.id}/#{inbox.id}/"
  end

  def endpoint_label
    "#{ENDPOINT_LABEL_PREFIX} account=#{account.id} inbox=#{inbox.id}"
  end

  def not_found?(error)
    error.details.to_h[:http_status] == 404
  end

  def operation(action, name, refs)
    { action: action, endpoint_name: name }.merge(refs).compact
  end
end
