class Whatsapp::CallRtpGateReport
  HEADER_ONLY_RECORDING_BYTES = 96

  def initialize(calls:, log_lines: [])
    @calls = calls
    @log_lines = log_lines
  end

  def call
    sessions = @calls.each_with_object({}) do |call_row, result|
      call_data = normalize_hash(call_row)
      session_id = call_data[:media_session_id]
      next if session_id.blank?

      stats = session_stats.fetch(session_id, {})
      issues = issues_for(call_data, stats)

      result[session_id] = {
        call_id: call_data[:id],
        direction: call_data[:direction],
        status: call_data[:status],
        duration_seconds: call_data[:duration_seconds],
        recording_file_size_bytes: recording_file_size(call_data),
        agent_to_meta_packets: stats.fetch(:agent_to_meta_packets, 0),
        meta_to_agent_packets: stats.fetch(:meta_to_agent_packets, 0),
        live_pass: issues.empty?,
        failure_stage: issues.first,
        issues: issues
      }
    end

    { sessions: sessions, summary: summary_for(sessions.values) }
  end

  private

  def session_stats
    @session_stats ||= @log_lines.each_with_object({}) do |line, result|
      parsed = parse_log_line(line)
      next if parsed.blank?

      session_id = parsed[:session_id]
      next if session_id.blank?

      current = result[session_id] ||= {
        agent_to_meta_packets: 0,
        meta_to_agent_packets: 0,
        agent_to_meta_payload_bytes: 0,
        meta_to_agent_payload_bytes: 0
      }

      if parsed[:msg] == 'bridge: stopped'
        current[:agent_to_meta_packets] = parsed[:agent_to_meta_packets].to_i
        current[:meta_to_agent_packets] = parsed[:meta_to_agent_packets].to_i
        current[:agent_to_meta_payload_bytes] = parsed[:agent_to_meta_payload_bytes].to_i
        current[:meta_to_agent_payload_bytes] = parsed[:meta_to_agent_payload_bytes].to_i
      elsif parsed[:msg] == 'bridge: Meta audio RTP flowing to agents'
        current[:meta_to_agent_packets] = [current[:meta_to_agent_packets], parsed[:packets].to_i].max
        current[:meta_to_agent_payload_bytes] = [current[:meta_to_agent_payload_bytes], parsed[:payload_bytes].to_i].max
      elsif parsed[:msg] == 'bridge: agent audio RTP flowing to Meta'
        current[:agent_to_meta_packets] = [current[:agent_to_meta_packets], parsed[:packets].to_i].max
        current[:agent_to_meta_payload_bytes] = [current[:agent_to_meta_payload_bytes], parsed[:payload_bytes].to_i].max
      end
    end
  end

  def issues_for(call_data, stats)
    issues = []
    issues << 'agent_to_meta_rtp_missing' if stats.fetch(:agent_to_meta_packets, 0).zero?
    issues << 'meta_to_agent_rtp_missing' if stats.fetch(:meta_to_agent_packets, 0).zero?
    issues << 'header_only_recording' if recording_file_size(call_data).to_i <= HEADER_ONLY_RECORDING_BYTES
    issues
  end

  def recording_file_size(call_data)
    call_data[:recording_file_size_bytes] || call_data.dig(:meta, :media_server, :callbacks, :recording_file_size_bytes)
  end

  def summary_for(session_reports)
    issue_counts = session_reports.each_with_object(Hash.new(0)) do |session_report, counts|
      session_report[:issues].each { |issue| counts[issue.to_sym] += 1 }
    end

    {
      total: session_reports.size,
      live_pass: session_reports.count { |session_report| session_report[:live_pass] },
      failed: session_reports.count { |session_report| !session_report[:live_pass] }
    }.merge(issue_counts)
  end

  def parse_log_line(line)
    json_start = line.index('{')
    return if json_start.blank?

    normalize_hash(JSON.parse(line[json_start..]))
  rescue JSON::ParserError
    nil
  end

  def normalize_hash(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key.to_sym] = normalize_hash(item)
      end
    when Array
      value.map { |item| normalize_hash(item) }
    else
      value
    end
  end
end
