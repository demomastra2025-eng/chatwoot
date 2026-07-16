require 'safe_fetch'

class Api::V1::Accounts::Telephony::CallsController < Api::V1::Accounts::Telephony::BaseController
  skip_before_action :authenticate_user!, :ensure_active_auth_session!, only: [:recording], raise: false

  before_action :set_call_session, only: [:show, :recording, :upload_recording]
  before_action :authenticate_recording_request!, only: [:recording]

  def index
    sessions = Current.account.telephony_call_sessions
    sessions = sessions.where(inbox_id: params[:inbox_id]) if params[:inbox_id].present?
    sessions = sessions.where(direction: params[:direction]) if params[:direction].present?
    sessions = Telephony::LogicalCallHistoryQuery.new(
      relation: sessions,
      limit: limit_param,
      status: params[:status]
    ).call
    sessions = preload_call_session_associations(sessions)

    render_payload(
      sessions.map(&:to_telephony_h),
      meta: { count: sessions.size }
    )
  end

  def show
    payload = @call_session.to_telephony_h
    payload[:recording_url] = recording_url_for_call_session if recording_available?
    render_payload(payload)
  end

  def recording
    authorize_recording_access!

    path = recording_file_path
    if path.present?
      send_local_recording_file(path)
      return
    end

    if external_recording_url.present?
      if proxy_external_recording?
        proxy_external_recording!
        return
      end

      redirect_to external_recording_url, allow_other_host: true
      return
    end

    raise ActiveRecord::RecordNotFound, 'Recording could not be found'
  end

  def upload_recording
    authorize_recording_upload!

    release_outbound_browser_call_from_recording!
    result = Telephony::BrowserRecordingUploadService.perform!(
      call_session: @call_session,
      recording: params[:recording],
      duration_ms: params[:duration_ms],
      duration_seconds: params[:duration_seconds]
    )
    @call_session = result.call_session.reload
    payload = @call_session.to_telephony_h
    payload[:recording_url] = recording_url_for_call_session if recording_available?

    render_payload(payload, status: :created)
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
      communication_thread_id: communication_thread_id_for(result[:conversation]),
      inbox_id: inbox.id,
      call_sid: result[:call_sid],
      conference_sid: result[:conversation].additional_attributes['conference_sid'],
      browser_join_supported: result[:browser_join_supported],
      call_session: result[:call_session]&.to_telephony_h
    }, status: :created
  end

  private

  def preload_call_session_associations(sessions)
    ActiveRecord::Associations::Preloader.new(
      records: sessions,
      associations: [:contact, :conversation, :inbox, :number_binding, :agent_binding]
    ).call
    sessions
  end

  def release_outbound_browser_call_from_recording!
    return unless @call_session.direction == 'outbound'
    return if params[:terminal_status].blank?

    Telephony::OperatorCallRejectService.new(
      account: Current.account,
      user: Current.user,
      call_ref: @call_session.external_call_ref,
      status: params[:terminal_status],
      reason: params[:reason]
    ).perform
  end

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

  def authorize_recording_upload!
    authorize_recording_access!
    return if recording_upload_owned_by_current_user?

    raise ActiveRecord::RecordNotFound, 'Recording could not be found'
  end

  def recording_upload_owned_by_current_user?
    return false if Current.user.blank?
    return true if @call_session.agent_binding&.user_id == Current.user.id
    return true if recording_upload_user_ids.include?(Current.user.id)
    return true if recording_upload_owned_sip_profile?

    false
  end

  def recording_upload_owned_sip_profile?
    sip_profile_ids = recording_upload_sip_profile_ids
    return false if sip_profile_ids.blank?

    Current.account.telephony_sip_profiles
           .exists?(id: sip_profile_ids, user_id: Current.user.id)
  end

  def recording_upload_user_ids
    route_metadata = call_session_route_metadata
    operator_claim = call_session_hash_metadata('operator_claim')
    operator_identity = call_session_hash_metadata('operator_identity')
    values = [
      operator_claim['user_id'],
      operator_claim['chatwoot_user_id'],
      operator_identity['user_id'],
      operator_identity['chatwoot_user_id'],
      route_metadata['chatwoot_user_id'],
      route_metadata['onelink_user_id'],
      route_metadata['target_user_id'],
      route_metadata['user_id']
    ]

    values.filter_map { |value| value.presence&.to_i }.uniq
  end

  def recording_upload_sip_profile_ids
    route_metadata = call_session_route_metadata
    operator_claim = call_session_hash_metadata('operator_claim')
    operator_identity = call_session_hash_metadata('operator_identity')
    values = [
      operator_claim['sip_profile_id'],
      operator_identity['sip_profile_id'],
      operator_identity['telephony_sip_profile_id'],
      route_metadata['sip_profile_id'],
      route_metadata['telephony_sip_profile_id'],
      route_metadata['target_sip_profile_id']
    ]

    values.filter_map { |value| value.presence&.to_i }.uniq
  end

  def call_session_route_metadata
    call_session_hash_metadata('metadata')
  end

  def call_session_hash_metadata(key)
    value = call_session_metadata[key]
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end

  def call_session_metadata
    @call_session.metadata.to_h.deep_stringify_keys
  end

  def recording_available?
    recording_storage_key.present? || external_recording_url.present?
  end

  def recording_url_for_call_session
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
    recording_metadata['storage_key'].presence || recording_metadata['recording_ref'].presence || @call_session.recording_ref.presence
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
    recording_token_storage_candidates.any? do |storage_key|
      Telephony::CallRecordingPlaybackUrl.valid?(
        token: params[Telephony::CallRecordingPlaybackUrl::TOKEN_PARAM],
        call_session: @call_session,
        storage_key: storage_key
      )
    end
  end

  def recording_content_type
    content_type = recording_metadata['content_type'].to_s
    return content_type if content_type.start_with?('audio/')

    'audio/wav'
  end

  def proxy_external_recording?
    Telephony::ExternalRecordingPlaybackPolicy.proxy?(external_recording_url)
  end

  def proxy_external_recording!
    result = Telephony::ExternalRecordingPlaybackProxy.fetch(
      url: external_recording_url,
      fallback_content_type: recording_content_type,
      fallback_filename: proxy_recording_filename
    )
    Telephony::ExternalRecordingCacheService.cache(
      call_session: @call_session,
      external_recording_url: external_recording_url,
      result: result,
      source: 'external_recording_proxy'
    )
    send_data(result.data, type: result.content_type, disposition: 'inline', filename: result.filename)
  rescue SafeFetch::Error => e
    Rails.logger.warn(
      "TELEPHONY_EXTERNAL_RECORDING_PROXY_FAILED account_id=#{@call_session.account_id} " \
      "call_session_id=#{@call_session.id} provider=#{@call_session.provider} error_class=#{e.class.name} message=#{e.message}"
    )
    head :bad_gateway
  end

  def send_local_recording_file(path)
    send_file(
      path,
      type: recording_content_type,
      disposition: 'inline',
      filename: File.basename(path),
      x_sendfile: true
    )
  end

  def proxy_recording_filename
    basename = URI.parse(external_recording_url).path.split('/').last.presence
    return basename if basename.present? && basename.include?('.')

    "call-recording-#{@call_session.id}.wav"
  rescue URI::InvalidURIError
    "call-recording-#{@call_session.id}.wav"
  end

  def recording_metadata
    metadata = @call_session.metadata
    recording = metadata.is_a?(Hash) ? metadata['recording'] : nil
    recording.is_a?(Hash) ? recording : {}
  end

  def recording_token_storage_candidates
    [
      recording_storage_key,
      external_recording_url,
      recording_metadata['recording_ref'],
      recording_metadata['recording_url'],
      @call_session.recording_ref
    ].compact_blank.map(&:to_s).uniq
  end

  def calls_service
    @calls_service ||= Telephony::CallsService.new(account: Current.account)
  end

  def communication_thread_id_for(conversation)
    return unless conversation.account&.feature_enabled?('communication_threads')

    communication_thread = conversation.communication_thread || conversation.refresh_communication_thread!
    communication_thread&.display_id
  end

  def limit_param
    value = params[:limit].to_i
    return 50 if value <= 0

    [value, 100].min
  end
end
