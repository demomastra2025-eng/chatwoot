# frozen_string_literal: true

require 'open3'

class Telephony::CallTranscript
  LINE = /\A(?:\[(?<time>\d{1,2}:\d{2}(?::\d{2})?)\]\s*)?(?<role>Сотрудник|Оператор|Клиент|Говорящий|Operator|Client):\s*(?<text>.+)\z/i
  LABELS = { 'operator' => 'Сотрудник', 'client' => 'Клиент', 'unknown' => 'Говорящий' }.freeze

  def self.probe(path)
    stdout, _stderr, status = Open3.capture3(
      'ffprobe', '-v', 'error', '-select_streams', 'a:0',
      '-show_entries', 'stream=channels,channel_layout:format=duration', '-of', 'json', path.to_s
    )
    return {} unless status.success?

    result = JSON.parse(stdout)
    stream = result.fetch('streams', []).first || {}
    {
      'channels' => stream['channels']&.to_i,
      'channel_layout' => stream['channel_layout'],
      'duration_seconds' => result.dig('format', 'duration')&.to_f
    }.compact
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def self.channel_activity(path, duration_seconds:)
    return {} if Llm::OpenRouterAudioInput.ffmpeg_path.blank?

    limit = duration_seconds.to_f.positive? ? [duration_seconds.to_f, 300.0].min : 300.0
    %w[0 1].to_h do |channel|
      _stdout, stderr, status = Open3.capture3(
        Llm::OpenRouterAudioInput.ffmpeg_path, '-nostdin', '-hide_banner', '-t', '300', '-i', path.to_s,
        '-af', "pan=mono|c0=c#{channel},silencedetect=noise=-35dB:d=0.3", '-f', 'null', '-'
      )
      [channel, status.success? ? active_intervals(stderr, limit) : []]
    end
  rescue Errno::ENOENT
    {}
  end

  def self.from_segments(segments, channel_activity: {}, roles: %w[operator client])
    Array(segments).filter_map do |seg|
      data = seg.to_h.stringify_keys
      start_sec = data['start'].to_f
      end_sec = [data['end'].to_f, start_sec + 0.1].max
      speaker = segment_speaker(start_sec, end_sec, channel_activity, roles)
      normalize_item('speaker' => speaker, 'start_sec' => start_sec.floor, 'text' => data['text'])
    end
  end

  def self.segment_speaker(start_sec, end_sec, activity, roles)
    c0 = Array(activity['0'])
    c1 = Array(activity['1'])
    return roles.first if c0.empty? && c1.empty?

    o0 = c0.sum { |s, e| [[end_sec, e.to_f].min - [start_sec, s.to_f].max, 0.0].max }
    o1 = c1.sum { |s, e| [[end_sec, e.to_f].min - [start_sec, s.to_f].max, 0.0].max }
    o1 > o0 ? roles.last : roles.first
  end

  def self.active_intervals(output, duration)
    cursor = 0.0
    intervals = []
    output.scan(/silence_(start|end):\s*([\d.]+)/).each do |kind, raw_time|
      time = raw_time.to_f
      if kind == 'start'
        intervals << [cursor.round(1), time.round(1)] if time - cursor >= 0.3
      else
        cursor = time
      end
    end
    intervals << [cursor.round(1), duration.round(1)] if duration - cursor >= 0.3
    intervals.first(40)
  end

  def self.parse(raw)
    data = decode(raw)
    items = Array(data['transcript_items']).filter_map { |item| normalize_item(item) }
    items = parse_lines(data['text'].to_s) if items.empty?
    { 'text' => items.any? ? format(items) : data['text'].to_s.strip, 'transcript_items' => items,
      'summary' => data['summary'].to_s.strip, 'outcome' => data['outcome'].to_s.strip,
      'topics' => Array(data['topics']).first(5).map(&:to_s).reject(&:blank?) }
  end

  def self.decode(raw)
    cleaned = raw.to_s.strip.sub(/\A```(?:json)?\s*/, '').sub(/\s*```\z/, '')
    parsed = cleaned.start_with?('{') ? JSON.parse(cleaned) : { 'text' => cleaned }
    parsed['transcript_items'] ||= parsed['items'] if parsed.is_a?(Hash) && parsed['items'].present?
    parsed
  rescue JSON::ParserError
    { 'text' => raw.to_s.strip }
  end

  def self.parse_lines(text)
    lines = text.to_s.lines.reject(&:blank?)
    items = lines.filter_map { |line| parse_line(line) }
    items.size == lines.size ? items : []
  end

  def self.parse_line(line)
    match = LINE.match(line.strip)
    return unless match

    speaker = match[:role].match?(/Клиент|Client/i) ? 'client' : 'operator'
    speaker = 'unknown' if match[:role].casecmp?('Говорящий')
    timestamp = match[:time]
    { 'speaker' => speaker, 'speaker_label' => LABELS.fetch(speaker), 'timestamp' => timestamp,
      'start_sec' => timestamp && timestamp.split(':').map(&:to_i).reduce(0) { |seconds, part| (seconds * 60) + part },
      'text' => match[:text].strip }.compact
  end

  def self.normalize_item(raw)
    return normalize_array_item(raw) if raw.is_a?(Array)

    item = raw.to_h.stringify_keys
    text = item['text'].to_s.strip
    return if text.blank?

    speaker = speaker_for(item['speaker'])
    seconds = seconds_for(item)
    timestamp = item['timestamp'].presence || timestamp_for(seconds)
    { 'speaker' => speaker, 'speaker_label' => LABELS.fetch(speaker), 'timestamp' => timestamp,
      'start_sec' => seconds, 'end_sec' => item['end_sec'], 'channel' => item['channel'], 'text' => text }.compact
  end

  def self.normalize_array_item(raw)
    sec = raw[0].is_a?(Array) ? raw[0].first : raw[0]
    normalize_item('start_sec' => sec.to_i, 'speaker' => raw[1], 'text' => raw[2])
  end

  def self.speaker_for(value)
    return 'unknown' if value.to_s == 'unknown'

    value.to_s.match?(/\Acl\z|client|caller|customer|contact|user|клиент/i) ? 'client' : 'operator'
  end

  def self.seconds_for(item)
    if item['start_sec'].present?
      val = item['start_sec']
      val = val.first if val.is_a?(Array)
      return numeric_seconds(val)
    end
    return if item['timestamp'].blank?

    item['timestamp'].to_s.split(':').map(&:to_i).reduce(0) { |total, part| (total * 60) + part }
  end

  def self.numeric_seconds(value)
    value.is_a?(Numeric) && value.finite? ? value : value.to_i
  end

  def self.timestamp_for(seconds)
    return if seconds.nil?

    seconds = seconds.to_i
    Kernel.format('%<minutes>02d:%<seconds>02d', minutes: seconds / 60, seconds: seconds % 60)
  end

  def self.format(items)
    items.filter_map { |item| normalize_item(item) }.map do |item|
      prefix = item['timestamp'].present? ? "[#{item['timestamp']}] " : ''
      "#{prefix}#{item['speaker_label']}: #{item['text']}"
    end.join("\n")
  end
end
