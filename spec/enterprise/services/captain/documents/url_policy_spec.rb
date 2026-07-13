require 'rails_helper'

RSpec.describe Captain::Documents::UrlPolicy do
  before do
    allow(SafeFetch).to receive(:resolve_public_ip!).and_return('93.184.216.34')
  end

  describe '.normalize!' do
    it 'normalizes a public HTTP URL and removes fragments and trailing slash' do
      expect(described_class.normalize!('https://example.com/docs/#intro')).to eq('https://example.com/docs')
    end

    it 'rejects private addresses' do
      allow(SafeFetch).to receive(:resolve_public_ip!).with('169.254.169.254').and_raise(SafeFetch::UnsafeUrlError, 'unsafe')

      expect { described_class.normalize!('http://169.254.169.254/latest/meta-data') }
        .to raise_error(described_class::InvalidUrlError, 'unsafe')
    end
  end

  describe '.normalize_selected_urls!' do
    it 'deduplicates same-origin pages' do
      result = described_class.normalize_selected_urls!(
        ['https://example.com/a/', 'https://example.com/a#section', 'https://example.com/b'],
        root_url: 'https://example.com/docs',
        max_count: 3
      )

      expect(result).to eq(['https://example.com/a', 'https://example.com/b'])
    end

    it 'rejects off-domain pages' do
      expect do
        described_class.normalize_selected_urls!(
          ['https://external.example/page'],
          root_url: 'https://example.com/docs',
          max_count: 5
        )
      end.to raise_error(described_class::OffDomainUrlError)
    end

    it 'allows subdomains only when explicitly enabled' do
      result = described_class.normalize_selected_urls!(
        ['https://docs.example.com/page'],
        root_url: 'https://example.com',
        max_count: 5,
        allow_subdomains: true
      )

      expect(result).to eq(['https://docs.example.com/page'])
    end

    it 'enforces the server-side page limit' do
      expect do
        described_class.normalize_selected_urls!(
          ['https://example.com/a', 'https://example.com/b'],
          root_url: 'https://example.com',
          max_count: 1
        )
      end.to raise_error(described_class::TooManyUrlsError, /1/)
    end
  end
end
