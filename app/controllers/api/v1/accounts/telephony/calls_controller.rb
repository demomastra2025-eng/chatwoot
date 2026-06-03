require 'net/http'

class Api::V1::Accounts::Telephony::CallsController < Api::V1::Accounts::Telephony::BaseController
  skip_before_action :authenticate_user!, :ensure_active_auth_session!, only: [:recording], raise: false

  before_action :set_call_session, only: [:show, :recording]
  before_action :authenticate_recording_request!, only: [:recording]

  def index
    sessions = Current.account.telephony_call_sessions.includes(:contact, :conversation, :inbox, :number_binding, :agent_binding).recent
    sessions = sessions.where(inbox_id: params[:inbox_id]) if params[:inbox_id].present?
    sessions = sessions.where(status: params[:status]) if params[:status].present?
    sessions = sessions.where(direction: params[:direction]) if params[:direction].present?
    sessions = sessions.limit(limit_param)

    render_payload(
      sessions.map(&:to_telephony_h),
      meta: { count: sessions.size }
    )
  end

  def show
    payload = @call_session.to_telephony_h
    payload[:recording_url] = recording_url_for_call_session if recording_available?
    payload[:bridge] = calls_service.find_remote(@call_session.external_call_ref) if parse_boolean(params[:include_bridge], default: false)
    render_payload(payload)
  end

  def recording
    authorize_recording_access!

    if external_recording_url.present?
      if proxy_external_recording?
        stream_external_recording!
        return
      end

      raise ActiveRecord::RecordNotFound, 'Recording could not be found' if sipuni_recording?

      redirect_to external_recording_url, allow_other_host: true
      return
    end

    path = recording_file_path
    raise ActiveRecord::RecordNotFound, 'Recording could not be found' if path.blank?

    send_file(
      path,
      type: recording_content_type,
      disposition: 'inline',
      filename: File.basename(path),
      x_sendfile: true
    )
  end

  def outbound
    contact = Current.account.contacts.find(params.require(:contact_id))
    inbox = Current.user.assigned_inboxes.where(account_id: Current.account.id, channel_type: 'Channel::Voice').find(params.require(:inbox_id))

    authorize contact, :show?
    authorize inbox, :show?

    result = Voice::OutboundCallBuilder.perform!(
      account: Current.account,
      inbox: inbox,
      user: Current.user,
      contact: contact
    )

    render json: {
      conversation_id: result[:conversation].display_id,
      inbox_id: inbox.id,
      call_sid: result[:call_sid],
      conference_sid: result[:conversation].additional_attributes['conference_sid'],
      call_session: result[:call_session]&.to_telephony_h
    }, status: :created
  end

  private

  def set_call_session
    @call_session = Current.account.telephony_call_sessions.find_by!(external_call_ref: params[:call_ref])
  end

  def authorize_recording_access!
    return if @signed_recording_request_authorized

    if @call_session.conversation.present?
      authorize @call_session.conversation, :show?
      return
    end

    if @call_session.inbox.present?
      authorize @call_session.inbox, :show?
      return
    end

    raise ActiveRecord::RecordNotFound, 'Recording could not be found'
  end

  def recording_available?
    return false if unsafe_sipuni_external_recording?

    recording_storage_key.present? || external_recording_url.present?
  end

  def recording_url_for_call_session
    return if unsafe_sipuni_external_recording?
    return signed_recording_url_for_call_session if proxy_external_recording?

    external_recording_url || signed_recording_url_for_call_session
  end

  def external_recording_url
    return @external_recording_url if defined?(@external_recording_url)

    @external_recording_url = parsed_external_recording_url
  end

  def parsed_external_recording_url
    candidate = recording_metadata['recording_url'].presence || recording_metadata['recording_ref'].presence || @call_session.recording_ref.presence
    return if candidate.blank?

    uri = URI.parse(candidate.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def proxy_external_recording?
    sipuni_recording? && sipuni_recording_url?(external_recording_url)
  end

  def unsafe_sipuni_external_recording?
    sipuni_recording? && external_recording_url.present? && !proxy_external_recording?
  end

  def sipuni_recording?
    @call_session.provider == 'sipuni'
  end

  def stream_external_recording!
    response = fetch_external_recording(URI.parse(external_recording_url))
    raise ActiveRecord::RecordNotFound, 'Recording could not be found' unless response.is_a?(Net::HTTPSuccess)

    content_type = external_recording_content_type(response)
    send_data(
      response.body,
      type: content_type,
      disposition: 'inline',
      filename: external_recording_filename(content_type)
    )
  rescue URI::InvalidURIError
    raise ActiveRecord::RecordNotFound, 'Recording could not be found'
  end

  def fetch_external_recording(uri, redirects_left = 2)
    return unless sipuni_recording_uri?(uri)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 30) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    return follow_external_recording_redirect(uri, response, redirects_left) if response.is_a?(Net::HTTPRedirection)

    response
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse,
         Net::ProtocolError, OpenSSL::SSL::SSLError, SocketError
    nil
  end

  def follow_external_recording_redirect(uri, response, redirects_left)
    return response unless redirects_left.positive?

    location = response['location'].to_s
    return response if location.blank?

    next_uri = URI.parse(location)
    next_uri = uri + location if next_uri.relative?
    fetch_external_recording(next_uri, redirects_left - 1)
  rescue URI::InvalidURIError
    response
  end

  def sipuni_recording_url?(url)
    Sipuni::RecordingUrl.allowed?(url)
  end

  def sipuni_recording_uri?(uri)
    Sipuni::RecordingUrl.allowed?(uri)
  end

  def external_recording_content_type(response)
    content_type = response['Content-Type'].to_s.split(';').first
    return content_type if content_type.start_with?('audio/')

    recording_content_type
  end

  def external_recording_filename(content_type)
    extension = content_type.to_s.split('/').last
    extension = 'wav' if extension.blank? || extension == 'x-wav'
    "call-#{@call_session.external_call_ref}.#{extension}"
  end

  def recording_file_path
    storage_key = recording_storage_key
    return if storage_key.blank?

    return unless storage_key.start_with?('voice-recordings/')

    storage_root = Rails.root.join('storage').realpath
    path = storage_root.join(storage_key).cleanpath
    return unless path.to_s.start_with?("#{storage_root}/")
    return unless File.file?(path)

    real_path = Pathname.new(File.realpath(path.to_s))
    return unless real_path.to_s.start_with?("#{storage_root}/")

    real_path.to_s
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    nil
  end

  def recording_storage_key
    candidate = recording_metadata['storage_key'].presence || recording_metadata['recording_ref'].presence || @call_session.recording_ref.presence
    return if sipuni_recording? && http_url?(candidate) && !Sipuni::RecordingUrl.allowed?(candidate)

    candidate
  end

  def http_url?(value)
    return false if value.blank?

    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def authenticate_recording_request!
    if signed_recording_request?
      raise ActiveRecord::RecordNotFound, 'Recording could not be found' unless valid_signed_recording_request?

      @signed_recording_request_authorized = true
      return
    end

    if authenticate_by_access_token?
      authenticate_access_token!
      validate_bot_access_token!
      return
    end

    authenticate_user!
    ensure_active_auth_session!
  end

  def signed_recording_url_for_call_session
    Telephony::CallRecordingPlaybackUrl.path_for(@call_session, storage_key: recording_storage_key)
  end

  def signed_recording_request?
    params[Telephony::CallRecordingPlaybackUrl::TOKEN_PARAM].present?
  end

  def valid_signed_recording_request?
    Telephony::CallRecordingPlaybackUrl.valid?(
      token: params[Telephony::CallRecordingPlaybackUrl::TOKEN_PARAM],
      call_session: @call_session,
      storage_key: recording_storage_key
    )
  end

  def recording_content_type
    content_type = recording_metadata['content_type'].to_s
    return content_type if content_type.start_with?('audio/')

    'audio/wav'
  end

  def recording_metadata
    metadata = @call_session.metadata
    recording = metadata.is_a?(Hash) ? metadata['recording'] : nil
    recording.is_a?(Hash) ? recording : {}
  end

  def calls_service
    @calls_service ||= Telephony::CallsService.new(account: Current.account)
  end

  def limit_param
    value = params[:limit].to_i
    return 50 if value <= 0

    [value, 100].min
  end
end
