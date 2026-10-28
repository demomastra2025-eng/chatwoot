# frozen_string_literal: true

require 'csv'

class Telephony::CallTranscriptsExportService
  COLUMNS = %w[call_id external_call_ref conversation_display_id inbox_id direction status started_at duration_seconds
               caller_number callee_number assignee_name channels outcome topics summary transcript].freeze

  def initialize(relation:, since:, until_at:, filters: {})
    @relation = relation
    @since = Time.zone.parse(since.to_s)
    @until_at = Time.zone.parse(until_at.to_s)
    @until_at = @until_at.end_of_day if until_at.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    raise ArgumentError, 'since and until are required' if @since.blank? || @until_at.blank?
    raise ArgumentError, 'until must be on or after since' if @until_at < @since

    @filters = filters
  end

  def rows
    calls = @relation.where(started_at: @since..@until_at)
    %i[inbox_id direction status].each do |filter|
      calls = calls.where(filter => @filters[filter]) if @filters[filter].present?
    end
    calls.includes(:conversation, agent_binding: :user).order(:started_at, :id).map { |call| row(call) }
  end

  def csv
    CSV.generate do |csv|
      csv << COLUMNS
      rows.each { |row| csv << COLUMNS.map { |column| csv_safe(row[column]) } }
    end
  end

  private

  def row(call)
    transcription = call.metadata.to_h.dig('recording', 'transcription').to_h
    recording = call.metadata.to_h['recording'].to_h
    items = Array(transcription['transcript_items'])
    text = items.present? ? Telephony::CallTranscript.format(items) : Telephony::CallTranscript.parse(transcription['text'])['text']
    identity_columns(call).merge(
      'channels' => transcription['channels'] || recording.dig('audio_probe', 'channels'),
      'outcome' => transcription['outcome'], 'topics' => Array(transcription['topics']),
      'summary' => transcription['summary'], 'transcript' => text
    )
  end

  def identity_columns(call)
    caller = call.direction == 'inbound' ? call.from_number : call.to_number
    callee = call.direction == 'inbound' ? call.to_number : call.from_number
    {
      'call_id' => call.id, 'external_call_ref' => call.external_call_ref,
      'conversation_display_id' => call.conversation&.display_id, 'inbox_id' => call.inbox_id,
      'direction' => call.direction, 'status' => call.status, 'started_at' => call.started_at&.iso8601,
      'duration_seconds' => call.duration_seconds, 'caller_number' => caller, 'callee_number' => callee,
      'assignee_name' => call.agent_binding&.user&.name
    }
  end

  def csv_safe(value)
    text = value.is_a?(Array) ? value.join(', ') : value.to_s
    text.match?(/\A\s*[=+@\-]/) ? "'#{text}" : text
  end
end
