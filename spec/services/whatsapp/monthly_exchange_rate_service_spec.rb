require 'rails_helper'

RSpec.describe Whatsapp::MonthlyExchangeRateService do
  let(:clock_state) { { now: Time.utc(2026, 11, 2, 12) } }
  let(:month) { Date.new(2026, 11, 1) }
  let(:service) { described_class.new(month: month, clock: -> { clock_state[:now] }) }
  let(:http) { instance_double(Net::HTTP) }
  let(:response) { http_response(Net::HTTPOK, '200', rates_xml) }
  let(:rates_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rates>
        <date>01.11.2026</date>
        <item><fullname>Euro</fullname><title>EUR</title><description>530.50</description><quant>1</quant></item>
        <item><fullname>US Dollar</fullname><title>USD</title><description>49930</description><quant>100</quant></item>
      </rates>
    XML
  end

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=).with(true)
    allow(http).to receive(:open_timeout=).with(Whatsapp::MonthlyExchangeRateSource::OPEN_TIMEOUT)
    allow(http).to receive(:read_timeout=).with(Whatsapp::MonthlyExchangeRateSource::READ_TIMEOUT)
    allow(http).to receive(:write_timeout=).with(Whatsapp::MonthlyExchangeRateSource::WRITE_TIMEOUT)
    allow(http).to receive(:max_retries=).with(0)
    allow(http).to receive(:start).and_yield(http)
    stub_http_responses(response)
  end

  it 'fetches the requested UTC month day and stores one USD rate normalized by its nominal units' do
    snapshot = service.perform

    expect(snapshot).to be_fetched
    expect(snapshot).to have_attributes(
      month_start: Date.new(2026, 11, 1),
      requested_date: Date.new(2026, 11, 1),
      effective_date: Date.new(2026, 11, 1),
      nominal_rate: BigDecimal(49_930),
      nominal_units: 100,
      rate_per_usd: BigDecimal('499.3'),
      source_url: 'https://nationalbank.kz/rss/get_rates.cfm?fdate=01.11.2026'
    )
    expect_configured_timeouts
    expect(http).to have_received(:request) do |request|
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq('/rss/get_rates.cfm?fdate=01.11.2026')
    end
  end

  it 'returns the persisted successful snapshot without another HTTP request' do
    first_snapshot = service.perform
    second_snapshot = service.perform

    expect(second_snapshot.id).to eq(first_snapshot.id)
    expect(http).to have_received(:request).once
  end

  it 'normalizes a time to its UTC report month before requesting the first day' do
    service = described_class.new(month: Time.new(2026, 11, 1, 1, 0, 0, '+03:00'), clock: -> { clock_state[:now] })
    october_xml = rates_xml.sub('01.11.2026', '01.10.2026')
    stub_http_responses(http_response(Net::HTTPOK, '200', october_xml))

    snapshot = service.perform

    expect(snapshot.month_start).to eq(Date.new(2026, 10, 1))
    expect(snapshot.requested_date).to eq(Date.new(2026, 10, 1))
    expect(http).to have_received(:request) do |request|
      expect(request.path).to eq('/rss/get_rates.cfm?fdate=01.10.2026')
    end
  end

  it 'parses the observed NBK XML shape and stores the October 1 USD rate' do
    october_xml = <<~XML
      <rates>
        <date>01.10.2026</date>
        <item>
          <fullname>Доллар США</fullname>
          <title>USD</title>
          <description>440.86</description>
          <quant>1</quant>
          <index>UP</index>
          <change>+1.49</change>
        </item>
      </rates>
    XML
    october_service = described_class.new(month: Date.new(2026, 10, 1), clock: -> { clock_state[:now] })
    stub_http_responses(http_response(Net::HTTPOK, '200', october_xml))

    snapshot = october_service.perform

    expect(snapshot).to have_attributes(
      requested_date: Date.new(2026, 10, 1),
      effective_date: Date.new(2026, 10, 1),
      nominal_rate: BigDecimal('440.86'),
      nominal_units: 1,
      rate_per_usd: BigDecimal('440.86')
    )
  end

  it 'rejects conflicting title and code currency values' do
    conflicting_xml = rates_xml.sub('<title>USD</title>', '<title>USD</title><code>EUR</code>')

    expect_unavailable(conflicting_xml, 'currency_code_conflict')
  end

  it 'caches an unavailable lookup for five minutes and retries after the cooldown' do
    unavailable_response = http_response(Net::HTTPServiceUnavailable, '503', '')
    stub_http_responses(unavailable_response, response)

    expect(service.perform).to be_nil
    failed_snapshot = WhatsappUsageExchangeRate.find_by!(month_start: month)
    expect(failed_snapshot).to have_attributes(status: 'unavailable', error_code: 'http_503')
    expect(failed_snapshot.retry_after).to eq(clock_state[:now] + described_class::RETRY_INTERVAL)
    expect(service.perform).to be_nil
    expect(http).to have_received(:request).once

    clock_state[:now] += described_class::RETRY_INTERVAL + 1.second

    expect(service.perform).to be_fetched
    expect(http).to have_received(:request).twice
  end

  it 'rejects XML with a DTD without resolving entities' do
    unsafe_xml = <<~XML
      <!DOCTYPE rates [<!ENTITY stolen SYSTEM "file:///etc/passwd">]>
      <rates><item><description>&stolen;</description><quant>1</quant><code>USD</code></item></rates>
    XML
    expect_unavailable(unsafe_xml, 'xml_dtd_not_allowed')
  end

  it 'rejects a malformed effective date' do
    malformed_date_xml = rates_xml.sub('01.11.2026', 'not-a-date')

    expect_unavailable(malformed_date_xml, 'invalid_effective_date')
  end

  it 'leaves an undated response unavailable rather than inventing its effective date' do
    undated_xml = rates_xml.sub('<date>01.11.2026</date>', '')

    expect_unavailable(undated_xml, 'effective_date_missing')
  end

  it 'rejects a rate effective after the requested month day' do
    future_date_xml = rates_xml.sub('01.11.2026', '02.11.2026')

    expect_unavailable(future_date_xml, 'future_effective_date')
  end

  it 'stops reading an oversized response as soon as its byte limit is exceeded' do
    response_limit = Whatsapp::MonthlyExchangeRateSource::MAX_RESPONSE_BYTES
    chunks = ['x' * (response_limit / 2), 'x' * (response_limit / 2), 'x', 'unread']
    chunks_yielded = 0
    oversized_response = http_response(Net::HTTPOK, '200', '')
    allow(oversized_response).to receive(:read_body) do |&chunk_handler|
      chunks.each do |chunk|
        chunks_yielded += 1
        chunk_handler.call(chunk)
      end
    end
    stub_http_responses(oversized_response)

    expect(service.perform).to be_nil
    expect(chunks_yielded).to eq(3)
    expect(WhatsappUsageExchangeRate.find_by!(month_start: month)).to have_attributes(
      status: 'unavailable', error_code: 'invalid_response_size'
    )
  end

  it 'caches a transport failure as unavailable' do
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)

    expect(service.perform).to be_nil
    expect(WhatsappUsageExchangeRate.find_by!(month_start: month)).to have_attributes(
      status: 'unavailable', error_code: 'transport_error'
    )
  end

  it 'caches a malformed HTTP response as unavailable for five minutes' do
    allow(http).to receive(:request).and_raise(Net::HTTPHeaderSyntaxError, 'malformed response header')

    expect(service.perform).to be_nil
    expect(WhatsappUsageExchangeRate.find_by!(month_start: month)).to have_attributes(
      status: 'unavailable',
      error_code: 'transport_error',
      retry_after: clock_state[:now] + described_class::RETRY_INTERVAL
    )
    expect(service.perform).to be_nil
    expect(http).to have_received(:request).once
  end

  it 'leaves a malformed HTTP status line unavailable' do
    allow(http).to receive(:request).and_raise(Net::HTTPBadResponse, 'malformed response status')

    expect(service.perform).to be_nil
    expect(WhatsappUsageExchangeRate.find_by!(month_start: month)).to have_attributes(
      status: 'unavailable', error_code: 'transport_error'
    )
  end

  def stub_http_responses(*responses)
    allow(http).to receive(:request) do |_request, &response_block|
      response = responses.shift
      response_block&.call(response)
      response
    end
  end

  def expect_configured_timeouts
    expect(http).to have_received(:open_timeout=).with(Whatsapp::MonthlyExchangeRateSource::OPEN_TIMEOUT)
    expect(http).to have_received(:read_timeout=).with(Whatsapp::MonthlyExchangeRateSource::READ_TIMEOUT)
    expect(http).to have_received(:write_timeout=).with(Whatsapp::MonthlyExchangeRateSource::WRITE_TIMEOUT)
  end

  def expect_unavailable(xml, error_code)
    stub_http_responses(http_response(Net::HTTPOK, '200', xml))

    expect(service.perform).to be_nil
    expect(WhatsappUsageExchangeRate.find_by!(month_start: month)).to have_attributes(
      status: 'unavailable', error_code: error_code
    )
  end

  def http_response(response_class, code, body)
    response_class.new('1.1', code, 'response').tap do |response|
      allow(response).to receive(:read_body) do |&chunk_handler|
        each_body_chunk(body, &chunk_handler)
        response
      end
    end
  end

  def each_body_chunk(body)
    offset = 0
    while offset < body.bytesize
      chunk = body.byteslice(offset, 64 * 1024)
      yield chunk
      offset += chunk.bytesize
    end
  end
end
