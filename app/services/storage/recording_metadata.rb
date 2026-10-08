# frozen_string_literal: true

# Sizes written by ingestion/compression, or measured by the background inventory. No filesystem access.
module Storage::RecordingMetadata
  module_function

  SIZE_PATTERN = /\A\d{1,18}\z/
  MEASUREMENT_MAX_AGE = 24.hours

  def size(value)
    value.to_i if value.to_s.match?(SIZE_PATTERN)
  end

  def hash(value)
    value.is_a?(Hash) ? value : {}
  end

  def local_key(reference, account_id:)
    value = reference.to_s
    root = "#{Storage::RecordingPaths.root.expand_path}/"
    value = value.delete_prefix(root)
    parts = value.split('/')
    return if parts.any? { |part| %w[. ..].include?(part) }

    voice = parts.first == 'voice-recordings' &&
            ((parts[1] == account_id.to_s && parts.length >= 3) ||
             (parts[1].present? && !parts[1].match?(/\A\d+\z/) && parts[2] == account_id.to_s && parts.length >= 4))
    trash = parts.first == 'trash' && parts[1] == account_id.to_s && parts[2] == 'recordings' && parts.length >= 4
    value if voice || trash
  end

  def declared_primary_size(session)
    recording = hash(hash(session.metadata)['recording'])
    return if recording['storage_key'].present? && recording['storage_key'] != session.recording_ref
    return unless local_key(session.recording_ref, account_id: session.account_id)

    size(recording['byte_size'])
  end

  def primary_size(session)
    declared = declared_primary_size(session)
    sample = hash(hash(hash(session.metadata)['storage_metrics'])['primary'])
    measured_size(sample, reference: session.recording_ref, account_id: session.account_id, declared_size: declared) || declared
  end

  # A legacy basename is usable only with a saved canonical path measured inside this tenant's tree.
  # Proofless old samples are reconciled again in the background rather than trusted by HTTP reads.
  def measured_size(sample, reference:, account_id:, declared_size:)
    return unless measured_key(sample, reference: reference, account_id: account_id)
    return unless sample['ref'] == reference && sample['declared_size'] == declared_size && recent?(sample['checked_at'])

    size(sample['byte_size'])
  end

  def measured_key(sample, reference:, account_id:)
    return unless sample['account_id'].to_s == account_id.to_s

    key = local_key(sample['key'], account_id: account_id)
    return unless key.present? && sample['key'] == key
    return key if local_key(reference, account_id: account_id) == key
    return unless legacy_basename?(reference) && key.split('/').last == reference

    key
  end

  def legacy_basename?(reference)
    reference.is_a?(String) && reference.present? && reference.match?(/\A[^\/\\:]+\z/) && %w[. ..].exclude?(reference)
  end

  def recent?(timestamp)
    seconds = size(timestamp)
    seconds.present? && seconds.between?(MEASUREMENT_MAX_AGE.ago.to_i, Time.current.to_i)
  end

  def tenant_layout_pattern(account_id)
    id = Integer(account_id)
    "(voice-recordings/(#{id}/.+|[^/]*[^/0-9][^/]*/#{id}/.+)|trash/#{id}/recordings/.+)"
  end

  # Only references that can be resolved within this tenant require a missing-size reconciliation.
  def reconcilable_reference_sql(account_id:)
    connection = ActiveRecord::Base.connection
    root = Regexp.escape("#{Storage::RecordingPaths.root.expand_path}/")
    <<~SQL.squish
      ((recording_ref ~ #{connection.quote("^(#{root})?#{tenant_layout_pattern(account_id)}$")}
        AND recording_ref !~ '(^|/)[.]{1,2}(/|$)')
        OR (recording_ref !~ #{connection.quote('[/:\\\\]')} AND recording_ref NOT IN ('', '.', '..')))
    SQL
  end

  # The tenant predicate and filters run before ORDER/LIMIT. Cast only digit strings of a bounded length:
  # malformed legacy JSON must not abort a whole list, and foreign/remote references are never physical bytes.
  def primary_size_sql(account_id:)
    connection = ActiveRecord::Base.connection
    root = Regexp.escape("#{Storage::RecordingPaths.root.expand_path}/")
    tenant_layout = tenant_layout_pattern(account_id)
    local_pattern = "^(#{root})?#{tenant_layout}$"
    sample_key = "metadata #>> '{storage_metrics,primary,key}'"
    native = <<~SQL.squish
      CASE WHEN recording_ref ~ #{connection.quote(local_pattern)}
        AND recording_ref !~ '(^|/)[.]{1,2}(/|$)'
        AND (NULLIF(metadata #>> '{recording,storage_key}', '') IS NULL OR metadata #>> '{recording,storage_key}' = recording_ref)
        AND metadata #>> '{recording,byte_size}' ~ '^[0-9]{1,18}$'
      THEN (metadata #>> '{recording,byte_size}')::bigint END
    SQL
    <<~SQL.squish
      CASE WHEN metadata #>> '{storage_metrics,primary,ref}' = recording_ref
        AND metadata #>> '{storage_metrics,primary,account_id}' = #{connection.quote(account_id.to_s)}
        AND #{sample_key} ~ #{connection.quote("^#{tenant_layout}$")}
        AND #{sample_key} !~ '(^|/)[.]{1,2}(/|$)'
        AND (recording_ref = #{sample_key}
          OR recording_ref = #{connection.quote("#{Storage::RecordingPaths.root.expand_path}/")} || (#{sample_key})
          OR (recording_ref !~ #{connection.quote('[/:\\\\]')} AND recording_ref NOT IN ('.', '..')
            AND recording_ref = regexp_replace(#{sample_key}, '^.*/', '')))
        AND (metadata #>> '{storage_metrics,primary,declared_size}')::text IS NOT DISTINCT FROM (#{native})::text
        AND metadata #>> '{storage_metrics,primary,byte_size}' ~ '^[0-9]{1,18}$'
        AND CASE WHEN metadata #>> '{storage_metrics,primary,checked_at}' ~ '^[0-9]{1,18}$'
          THEN (metadata #>> '{storage_metrics,primary,checked_at}')::bigint END
          BETWEEN #{MEASUREMENT_MAX_AGE.ago.to_i} AND #{Time.current.to_i}
      THEN (metadata #>> '{storage_metrics,primary,byte_size}')::bigint
      ELSE #{native} END
    SQL
  end
end
