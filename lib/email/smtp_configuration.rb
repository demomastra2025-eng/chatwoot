module Email
  module SmtpConfiguration
    module_function

    def build_delivery_settings(base_settings:, ssl_enabled:, starttls_enabled:, openssl_verify_mode:)
      base_settings.merge(
        transport_security_options(
          ssl_enabled: ssl_enabled,
          starttls_enabled: starttls_enabled
        ).merge(
          openssl_verify_mode: openssl_verify_mode,
          ssl_context_params: ssl_context_params(openssl_verify_mode),
          tls_verify: tls_verify(openssl_verify_mode)
        )
      ).compact
    end

    def transport_security_options(ssl_enabled:, starttls_enabled:)
      return { ssl: true, tls: true, enable_starttls_auto: false } if ssl_enabled
      return { ssl: false, tls: false, enable_starttls_auto: true } if starttls_enabled

      { ssl: false, tls: false, enable_starttls_auto: false }
    end

    def ssl_context(openssl_verify_mode)
      apply_ssl_context_params(Net::SMTP.default_ssl_context, ssl_context_params(openssl_verify_mode))
    end

    def ssl_context_params(openssl_verify_mode)
      verify_mode = resolve_verify_mode(openssl_verify_mode)
      return {} unless verify_mode

      {
        verify_mode: verify_mode,
        verify_hostname: verify_mode != OpenSSL::SSL::VERIFY_NONE
      }
    end

    def tls_verify(openssl_verify_mode)
      verify_mode = resolve_verify_mode(openssl_verify_mode)
      return if verify_mode.nil?

      verify_mode != OpenSSL::SSL::VERIFY_NONE
    end

    def apply_ssl_context_params(context, params)
      params.each do |key, value|
        setter = "#{key}="
        context.public_send(setter, value) if context.respond_to?(setter)
      end
      context
    end

    def resolve_verify_mode(openssl_verify_mode)
      return if openssl_verify_mode.blank?
      return openssl_verify_mode unless openssl_verify_mode.is_a?(String)

      OpenSSL::SSL.const_get("VERIFY_#{openssl_verify_mode.upcase}")
    end
  end
end
