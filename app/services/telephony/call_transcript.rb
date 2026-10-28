# frozen_string_literal: true

require 'open3'

class Telephony::CallTranscript
  LINE = /\A(?:\[(?<time>\d{1,2}:\d{2}(?::\d{2})?)\]\s*)?(?<role>Сотрудник|Оператор|Клиент|Operator|Client):\s*(?<text>.+)\z/i
  LABELS = { 'operator' => 'Сотрудник', 'client' => 'Клиент' }.freeze

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

    %w[0 1].to_h do |channel|
      _stdout, stderr, status = Open3.capture3(
        Llm::OpenRouterAudioInput.ffmpeg_path, '-nostdin', '-hide_banner', '-t', '300', '-i', path.to_s,
        '-af', "pan=mono|c0=c#{channel},silencedetect=noise=-35dB:d=0.3", '-f', 'null', '-'
      )
      [channel, status.success? ? active_intervals(stderr, [duration_seconds.to_f, 300].min) : []]
    end
  rescue Errno::ENOENT
    {}
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
    cleaned.start_with?('{') ? JSON.parse(cleaned) : { 'text' => cleaned }
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
    timestamp = match[:time]
    { 'speaker' => speaker, 'speaker_label' => LABELS.fetch(speaker), 'timestamp' => timestamp,
      'start_sec' => timestamp && timestamp.split(':').map(&:to_i).reduce(0) { |seconds, part| (seconds * 60) + part },
      'text' => match[:text].strip }.compact
  end

  def self.normalize_item(raw)
    item = raw.to_h.stringify_keys
    text = item['text'].to_s.strip
    return if text.blank?

    speaker = speaker_for(item['speaker'])
    seconds = seconds_for(item)
    timestamp = item['timestamp'].presence || timestamp_for(seconds)
    { 'speaker' => speaker, 'speaker_label' => LABELS.fetch(speaker), 'timestamp' => timestamp,
      'start_sec' => seconds, 'text' => text }.compact
  end

  def self.speaker_for(value)
    value.to_s.match?(/client|caller|customer|contact|user|клиент/i) ? 'client' : 'operator'
  end

  def self.seconds_for(item)
    return item['start_sec'].to_i if item['start_sec'].present?
    return if item['timestamp'].blank?

    item['timestamp'].split(':').map(&:to_i).reduce(0) { |total, part| (total * 60) + part }
  end

  def self.timestamp_for(seconds)
    return if seconds.nil?

    Kernel.format('%<minutes>02d:%<seconds>02d', minutes: seconds / 60, seconds: seconds % 60)
  end

  def self.format(items)
    items.filter_map { |item| normalize_item(item) }.map do |item|
      prefix = item['timestamp'].present? ? "[#{item['timestamp']}] " : ''
      "#{prefix}#{item['speaker_label']}: #{item['text']}"
    end.join("\n")
  end
end
