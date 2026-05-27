FactoryBot.define do
  factory :platform_banner do
    banner_message { 'Scheduled maintenance is in progress. [Status page](https://status.one-link.kz)' }
    banner_type { :info }
    active { true }
  end
end
