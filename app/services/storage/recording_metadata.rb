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
    sample = hash(hash(session.metadata).dig('storage_metrics', 'primary'))
    if sample['ref'] == session.recording_ref && sample['declared_size'] == declared && recent?(sample['checked_at'])
      measured = size(sample['byte_size'])
      return measured unless measured.nil?
    end
    declared
  end

  def recent?(timestamp)
    timestamp.to_i >= MEASUREMENT_MAX_AGE.ago.to_i
  end

  # The tenant predicate and filters run before ORDER/LIMIT. Cast only digit strings of a bounded length:
  # malformed legacy JSON must not abort a whole list, and foreign/remote references are never physical bytes.
  def primary_size_sql(account_id:)
    connection = ActiveRecord::Base.connection
    root = Regexp.escape("#{Storage::RecordingPaths.root.expand_path}/")
    local_pattern = "^(#{root})?voice-recordings/(#{Integer(account_id)}/.+|[^/]+/#{Integer(account_id)}/.+)$"
    native = <<~SQL.squish
      CASE WHEN recording_ref ~ #{connection.quote(local_pattern)}
        AND recording_ref !~ '(^|/)[.]{1,2}(/|$)'
        AND recording_ref !~ 'voice-recordings/[0-9]+/[0-9]+/'
        AND (NULLIF(metadata #>> '{recording,storage_key}', '') IS NULL OR metadata #>> '{recording,storage_key}' = recording_ref)
        AND metadata #>> '{recording,byte_size}' ~ '^[0-9]{1,18}$'
      THEN (metadata #>> '{recording,byte_size}')::bigint END
    SQL
    <<~SQL.squish
      CASE WHEN metadata #>> '{storage_metrics,primary,ref}' = recording_ref
        AND (metadata #>> '{storage_metrics,primary,declared_size}')::text IS NOT DISTINCT FROM (#{native})::text
        AND metadata #>> '{storage_metrics,primary,byte_size}' ~ '^[0-9]{1,18}$'
        AND CASE WHEN metadata #>> '{storage_metrics,primary,checked_at}' ~ '^[0-9]{1,18}$'
          THEN (metadata #>> '{storage_metrics,primary,checked_at}')::bigint END >= #{MEASUREMENT_MAX_AGE.ago.to_i}
      THEN (metadata #>> '{storage_metrics,primary,byte_size}')::bigint
      ELSE #{native} END
    SQL
  end
end
