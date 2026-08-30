class Whatsapp::AuthenticatedMediaWebhookDispatch
  pattr_initialize [
    :channel!,
    :payload!,
    :verification_context!,
    :live_priority_token!,
    :outgoing_echo!,
    :dispatch_action!
  ]

  def perform
    @runtime_snapshot = route.verified_runtime_snapshot
    return false if runtime_snapshot == false

    @prepared_attachment = prepare_attachment
    if prepared_attachment.blank?
      dispatch_with_verified_route(nil)
      return true
    end

    download_and_dispatch
  ensure
    prepared_attachment&.close
  end

  private

  attr_reader :prepared_attachment, :runtime_snapshot

  def route
    @route ||= Whatsapp::AuthenticatedWebhookRoute.new(
      channel: channel,
      payload: payload,
      verification_context: verification_context,
      live_priority_token: live_priority_token
    )
  end

  def prepare_attachment
    return unless channel&.provider == 'whatsapp_cloud'

    Whatsapp::CloudMediaDownload.prepare(
      channel: channel,
      params: payload,
      outgoing_echo: outgoing_echo
    )
  end

  def download_and_dispatch
    prepared_attachment.download!
    dispatch_with_verified_route(prepared_attachment)

    true
  end

  def dispatch_with_verified_route(attachment)
    dispatched = route.with_verified_route(expected_runtime_snapshot: runtime_snapshot) do
      dispatch_action.call(attachment)
    end
    raise Whatsapp::AuthenticatedWebhookRoute::RuntimeIdentityChangedError unless dispatched
  end
end
