# frozen_string_literal: true

# The addresses of the platform that a person copies into the console of a service (Meta, Google, Microsoft, TikTok) when
# he connects it: where the service sends its events (the webhook) and where it returns the person after he agreed
# (the return address). They are built from the address of the platform, exactly as the application builds them, so
# they are shown as text to copy and never as a field to edit.
#
#   SuperAdmin::AppConfigAddresses.for('google', 'https://app.one-link.kz')
#   # => [#<struct kind=:redirect, url="https://app.one-link.kz/google/callback">]
module SuperAdmin::AppConfigAddresses
  Address = Struct.new(:kind, :url, keyword_init: true)

  # page => [[kind, path]]. The paths are the routes of the application (config/routes.rb): the Messenger webhook is
  # mounted at /bot; the return addresses are the ones the authorization controllers send to the service.
  PATHS = {
    'facebook' => [[:webhook, '/bot']],
    'instagram' => [[:webhook, '/webhooks/instagram'], [:redirect, '/instagram/callback']],
    'tiktok' => [[:webhook, '/webhooks/tiktok'], [:redirect, '/tiktok/callback']],
    'whatsapp_embedded' => [[:webhook, '/webhooks/whatsapp']],
    'google' => [[:redirect, '/google/callback']],
    'microsoft' => [[:redirect, '/microsoft/callback']]
  }.freeze

  module_function

  def for(config, base_url)
    base = base_url.to_s.chomp('/')
    PATHS.fetch(config.to_s, []).map { |kind, path| Address.new(kind: kind, url: "#{base}#{path}") }
  end

  # The address of the platform as the application itself builds its return addresses (FRONTEND_URL), or the address
  # the page was opened on
  def base_url(request)
    ENV['FRONTEND_URL'].presence || request.base_url
  end

  # The sign-in page of the application of the operators, on that address: what a person who was given a password opens
  def sign_in_url(request)
    "#{base_url(request).to_s.chomp('/')}/app/login"
  end
end
