module MailSmtpPatch
  private

  def build_smtp_session
    Net::SMTP.new(settings[:address], settings[:port]).tap do |smtp|
      apply_native_smtp_settings(smtp)
      configure_transport_security(smtp)

      smtp.open_timeout = settings[:open_timeout] if settings[:open_timeout]
      smtp.read_timeout = settings[:read_timeout] if settings[:read_timeout]
    end
  end

  def ssl_context
    context = super
    Email::SmtpConfiguration.apply_ssl_context_params(context, settings[:ssl_context_params] || {})
  end

  def apply_native_smtp_settings(smtp)
    smtp.tls_hostname = settings[:tls_hostname] if settings.key?(:tls_hostname) && smtp.respond_to?(:tls_hostname=)
    smtp.tls_verify = settings[:tls_verify] if settings.key?(:tls_verify) && smtp.respond_to?(:tls_verify=)
    smtp.ssl_context_params = settings[:ssl_context_params] if settings[:ssl_context_params] && smtp.respond_to?(:ssl_context_params=)
  end

  def configure_transport_security(smtp)
    return smtp.enable_tls(ssl_context) if tls_enabled?
    return configure_starttls(smtp) if starttls_setting_specified?
    return smtp.disable_tls if tls_disabled?
  end

  def tls_enabled?
    settings[:tls] == true || settings[:ssl] == true
  end

  def tls_disabled?
    settings[:tls] == false || settings[:ssl] == false
  end

  def starttls_setting_specified?
    settings.include?(:enable_starttls) || settings.include?(:enable_starttls_auto)
  end

  def configure_starttls(smtp)
    if settings.include?(:enable_starttls) && !settings[:enable_starttls].nil?
      return smtp.enable_starttls(ssl_context) if settings[:enable_starttls]
      return smtp.disable_starttls
    end

    return unless settings.include?(:enable_starttls_auto) && !settings[:enable_starttls_auto].nil?

    return smtp.enable_starttls_auto(ssl_context) if settings[:enable_starttls_auto]

    smtp.disable_starttls
  end
end

Mail::SMTP.prepend(MailSmtpPatch)
