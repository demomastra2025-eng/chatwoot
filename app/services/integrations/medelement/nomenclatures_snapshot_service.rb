class Integrations::Medelement::NomenclaturesSnapshotService
  PAGE_SIZE = 20
  MAX_PAGES = 1000
  PAGE_DELAY_SECONDS = 0.275
  PAGE_RETRY_BACKOFFS = [1, 5, 15].freeze
  CONTINUE = :continue

  def initialize(
    client:,
    sleeper: ->(seconds) { Kernel.sleep(seconds) },
    page_delay_seconds: PAGE_DELAY_SECONDS,
    page_retry_backoffs: PAGE_RETRY_BACKOFFS
  )
    @client = client
    @sleeper = sleeper
    @page_delay_seconds = page_delay_seconds
    @page_retry_backoffs = page_retry_backoffs
  end

  def perform
    reset_state

    MAX_PAGES.times do
      page = fetch_page
      empty_result = empty_page_result(page)
      return empty_result unless empty_result == CONTINUE

      consume_page!(page)
      return rows.first(expected_total) if complete?
      return rows if uncounted_last_page?(page)

      @skip += page.size
    end

    raise_incomplete_snapshot!
  end

  private

  attr_reader :client, :expected_total, :page_delay_seconds, :page_retry_backoffs, :rows, :seen_pages, :skip, :sleeper

  def fetch_page
    page = with_page_retry { Array(client.nomenclatures(skip: skip)) }
    sleeper.call(page_delay_seconds) if page_delay_seconds.positive?
    page
  end

  def with_page_retry
    attempt = 0

    begin
      yield
    rescue Integrations::Medelement::Client::ApiError => e
      raise unless e.retryable? && attempt < page_retry_backoffs.size

      sleeper.call(page_retry_backoffs.fetch(attempt))
      attempt += 1
      retry
    end
  end

  def reset_state
    @expected_total = nil
    @rows = []
    @seen_pages = Set.new
    @skip = 0
  end

  def empty_page_result(page)
    return CONTINUE if page.present?
    return rows if expected_total.nil? && rows.present?

    raise_incomplete_snapshot!
  end

  def consume_page!(page)
    @expected_total ||= total_count(page)
    fingerprint = page.map { |item| external_code(item.to_h.with_indifferent_access) }
    if seen_pages.include?(fingerprint)
      raise Integrations::Medelement::ServicesSyncService::IncompleteSnapshotError,
            'Medelement nomenclature pagination repeated a page'
    end

    seen_pages << fingerprint
    rows.concat(page)
  end

  def complete?
    expected_total.present? && rows.size >= expected_total
  end

  def uncounted_last_page?(page)
    expected_total.nil? && page.size < PAGE_SIZE
  end

  def total_count(page)
    value = page.first.to_h.with_indifferent_access['RECCOUNT']
    total = Integer(value, exception: false)
    total if total&.positive?
  end

  def external_code(payload)
    payload['serviceCode'].presence || payload['NOMENCLATURE_CODE'].presence
  end

  def raise_incomplete_snapshot!
    detail = expected_total.present? ? "expected=#{expected_total} received=#{rows.size}" : "received=#{rows.size}"
    raise Integrations::Medelement::ServicesSyncService::IncompleteSnapshotError,
          "Incomplete Medelement nomenclature snapshot: #{detail}"
  end
end
