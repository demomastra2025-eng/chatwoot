# frozen_string_literal: true

class Captain::Documents::UrlPolicy
  MAX_SELECTED_URLS = 500

  class InvalidUrlError < StandardError; end
  class OffDomainUrlError < InvalidUrlError; end
  class TooManyUrlsError < InvalidUrlError; end

  class << self
    def normalize!(value, resolve: true)
      uri = parse_http_uri!(value)
      validate_public_host!(uri.host) if resolve
      normalized_url(uri)
    rescue URI::InvalidURIError, SafeFetch::Error => e
      raise InvalidUrlError, e.message
    end

    def normalize_selected_urls!(values, root_url:, max_count:, allow_subdomains: false, resolve: true)
      root_uri = parse_http_uri!(root_url)
      normalized = Array(values).filter_map do |value|
        next if value.blank?

        uri = parse_http_uri!(value)
        unless allowed_for_root?(uri, root_uri, allow_subdomains: allow_subdomains)
          raise OffDomainUrlError, I18n.t('captain.documents.selected_page_off_domain')
        end

        normalized_url(uri)
      end.uniq

      limit = normalize_limit(max_count)
      raise TooManyUrlsError, I18n.t('captain.documents.selected_pages_limit', limit: limit) if normalized.size > limit

      validate_hosts!(normalized) if resolve
      normalized
    rescue URI::InvalidURIError, SafeFetch::Error => e
      raise InvalidUrlError, e.message
    end

    def allowed_for_root?(candidate, root, allow_subdomains: false)
      candidate = parse_http_uri!(candidate) unless candidate.is_a?(URI::HTTP)
      root = parse_http_uri!(root) unless root.is_a?(URI::HTTP)

      same_origin?(candidate, root) && allowed_host?(candidate.host, root.host, allow_subdomains: allow_subdomains)
    rescue URI::InvalidURIError, InvalidUrlError
      false
    end

    private

    def same_origin?(candidate, root)
      candidate.scheme == root.scheme && candidate.port == root.port
    end

    def allowed_host?(candidate_host, root_host, allow_subdomains:)
      candidate_host = candidate_host.to_s.downcase
      root_host = root_host.to_s.downcase
      return candidate_host == root_host unless allow_subdomains

      candidate_host == root_host || candidate_host.end_with?(".#{root_host}")
    end

    def parse_http_uri!(value)
      uri = URI.parse(value.to_s.strip)
      raise InvalidUrlError, I18n.t('captain.documents.invalid_public_url') unless uri.is_a?(URI::HTTP) && uri.host.present?
      raise InvalidUrlError, I18n.t('captain.documents.invalid_public_url') if uri.userinfo.present?

      uri
    end

    def normalized_url(uri)
      normalized = uri.dup
      normalized.fragment = nil
      normalized.path = '/' if normalized.path.blank?
      normalized.to_s.delete_suffix('/')
    end

    def validate_hosts!(urls)
      urls.filter_map { |url| URI.parse(url).host }.uniq.each { |host| validate_public_host!(host) }
    end

    def validate_public_host!(host)
      SafeFetch.resolve_public_ip!(host)
    end

    def normalize_limit(value)
      value.to_i.clamp(1, MAX_SELECTED_URLS)
    end
  end
end
