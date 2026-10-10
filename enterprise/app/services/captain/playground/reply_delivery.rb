class Captain::Playground::ReplyDelivery
  def initialize(_session)
  end

  def perform(_response)
    # Replies are session transcript entries. This also closes the legacy
    # Live delivery branch for queued/stale callers holding an old session.
    { enabled: false, status: 'playground_only', delivered: false }
  end
end
