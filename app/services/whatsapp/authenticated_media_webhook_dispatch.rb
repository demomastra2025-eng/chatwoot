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
    verified = route.with_verified_route { prepare_or_dispatch }
    return false unless verified
    return true if prepared_attachment.blank?

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

  def prepare_or_dispatch
    @prepared_attachment = prepare_attachment
    if prepared_attachment.present?
      @runtime_snapshot = route.runtime_snapshot
    else
      dispatch_action.call(nil)
    end
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
    dispatched = route.with_verified_route(expected_runtime_snapshot: runtime_snapshot) do
      dispatch_action.call(prepared_attachment)
    end
    raise Whatsapp::AuthenticatedWebhookRoute::RuntimeIdentityChangedError unless dispatched

    true
  end
end
